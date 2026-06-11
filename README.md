# Playbook: MySQL 8.0 → 8.4 Major Version Upgrade on AWS RDS using Blue/Green Deployments

A production-grade, step-by-step runbook for upgrading **Amazon RDS for MySQL 8.0** to **MySQL 8.4 (LTS)** with near-zero downtime using **RDS Blue/Green Deployments**.

> **Author:** Martin Baranek
> **Scope:** Amazon RDS for MySQL (single instance or Multi-AZ). Aurora MySQL notes are called out where the procedure differs.
> **Expected downtime at switchover:** typically well under one minute (plus client reconnect time).

---

## Table of Contents

1. [Why Blue/Green](#1-why-bluegreen)
2. [How it works](#2-how-it-works)
3. [Prerequisites](#3-prerequisites)
4. [MySQL 8.4 breaking changes you must check first](#4-mysql-84-breaking-changes-you-must-check-first)
5. [Phase 1 — Preflight checks](#5-phase-1--preflight-checks)
6. [Phase 2 — Prepare the 8.4 parameter group](#6-phase-2--prepare-the-84-parameter-group)
7. [Phase 3 — Create the Blue/Green deployment](#7-phase-3--create-the-bluegreen-deployment)
8. [Phase 4 — Validate the green environment](#8-phase-4--validate-the-green-environment)
9. [Phase 5 — Switchover](#9-phase-5--switchover)
10. [Phase 6 — Post-switchover validation](#10-phase-6--post-switchover-validation)
11. [Phase 7 — Cleanup](#11-phase-7--cleanup)
12. [Rollback strategy](#12-rollback-strategy)
13. [Limitations and gotchas](#13-limitations-and-gotchas)
14. [Helper scripts](#helper-scripts)

---

## 1. Why Blue/Green

An in-place major version upgrade of RDS MySQL takes the database **offline for the entire upgrade** (often 10–30+ minutes, depending on data dictionary size and table count). A Blue/Green deployment instead:

- Creates a **full copy of your production environment (green)** already running MySQL 8.4, kept in sync with production (blue) via **logical replication**.
- Lets you **test the upgraded environment with zero risk** to production — green is read-only until switchover.
- Performs the switchover with **built-in guardrails**: RDS blocks the switchover if replication is lagging, and it swaps the **DNS endpoints automatically**, so **no application connection-string change is needed**.
- Keeps the old (blue) environment running after switchover as an immediate fallback reference.

## 2. How it works

```
 Before switchover                          After switchover
 ─────────────────                          ────────────────
 app ──► mydb.xxxx.rds.amazonaws.com        app ──► mydb.xxxx.rds.amazonaws.com
              │                                          │
         ┌────▼─────┐   logical            ┌─────────────▼┐
         │  BLUE    │   replication        │   GREEN      │  (now production)
         │ MySQL 8.0│ ───────────────►     │  MySQL 8.4   │
         │ (prod)   │                      └──────────────┘
         └──────────┘                       ┌──────────────┐
         ┌──────────┐                       │  old BLUE    │  renamed *-old1,
         │  GREEN   │  read-only,           │  MySQL 8.0   │  kept for fallback
         │ MySQL 8.4│  green endpoint       └──────────────┘
         └──────────┘
```

RDS clones blue into green (from a snapshot), upgrades green to the target engine version, and starts binlog-based replication from blue to green. At switchover, RDS waits for replication to catch up, briefly blocks writes on blue, then **swaps the endpoint DNS records** — green becomes production under the original endpoint name.

## 3. Prerequisites

| Requirement | Why | How to check |
|---|---|---|
| **Automated backups enabled** (`BackupRetentionPeriod ≥ 1`) | Enables binary logging, which Blue/Green replication requires | `aws rds describe-db-instances --db-instance-identifier <id> --query 'DBInstances[0].BackupRetentionPeriod'` |
| **MySQL 8.4 is a valid upgrade target** from your current 8.0.x patch level | Some old 8.0 patch versions must be patched first | See [Phase 1](#5-phase-1--preflight-checks) |
| **A `mysql8.4` family DB parameter group** prepared in advance | Default parameter groups won't carry your custom settings; some 8.0 parameters were removed in 8.4 | [Phase 2](#6-phase-2--prepare-the-84-parameter-group) |
| **No cross-region read replicas** on the source | Not supported by Blue/Green | `aws rds describe-db-instances --db-instance-identifier <id> --query 'DBInstances[0].ReadReplicaDBInstanceIdentifiers'` |
| **No active zero-ETL integrations** on the source | Blue/Green deployments cannot be created while a zero-ETL integration (e.g. to Amazon Redshift) is attached — see [3.1](#31-zero-etl-integrations-must-be-removed-first) | `aws rds describe-integrations` |
| **IAM permissions** for `rds:CreateBlueGreenDeployment`, `rds:SwitchoverBlueGreenDeployment`, `rds:DeleteBlueGreenDeployment`, plus standard `rds:Describe*` | The whole workflow | IAM policy review |
| **Maintenance window agreed with stakeholders** | Switchover causes a brief (<1 min) write interruption | — |
| **Budget awareness** | Green doubles your instance + storage cost while it exists — keep the validation window short (days, not weeks) | — |

### 3.1 Zero-ETL integrations must be removed first

If the source database has an active **zero-ETL integration** (for example, streaming changes into Amazon Redshift), the Blue/Green deployment cannot be created. Plan for the following sequence:

1. **Before creating the Blue/Green deployment:** delete the zero-ETL integration. Record its full configuration first (target ARN, data filters, KMS key, tags) so it can be recreated identically.

   ```bash
   # Inventory integrations attached to the source
   aws rds describe-integrations --region "$REGION" \
     --query 'Integrations[].{Name:IntegrationName,Arn:IntegrationArn,Source:SourceArn,Target:TargetArn,Status:Status}'

   # Delete the one pointing at your blue instance
   aws rds delete-integration --integration-identifier <integration-arn> --region "$REGION"
   ```

2. **After a successful switchover** (Phase 6): recreate the integration against the new production environment.

   ```bash
   aws rds create-integration \
     --integration-name "<name>" \
     --source-arn "$SOURCE_ARN" \
     --target-arn "<redshift-namespace-arn>" \
     --region "$REGION"
   ```

> **Impact to plan for:** while the integration is deleted, no changes flow to the analytics target, and the recreated integration performs a **full initial re-seed** of the data. Coordinate the analytics-side gap with the consuming teams and schedule the upgrade window accordingly.

## 4. MySQL 8.4 breaking changes you must check first

MySQL 8.4 is an LTS release, but it **removes** features deprecated in 8.0. These are the items that actually break real-world upgrades:

### 4.1 `mysql_native_password` is disabled by default

In 8.4 the old authentication plugin is **disabled by default** (and fully removed in MySQL 9.x). Any account still using it must be migrated to `caching_sha2_password` **before** the upgrade, or your clients will fail to authenticate.

Find affected accounts:

```sql
SELECT user, host, plugin
FROM mysql.user
WHERE plugin = 'mysql_native_password';
```

Migrate each account (coordinate with the application owner — the client library must support `caching_sha2_password`; all maintained connectors do):

```sql
ALTER USER 'app_user'@'%' IDENTIFIED WITH caching_sha2_password BY '<password>';
```

> Old client libraries (e.g. very old PHP `mysqli`, pre-8.0 Connector/J) may not support `caching_sha2_password`. Verify driver versions across **all** consuming applications first.

### 4.2 Removed server parameters

Parameters removed between 8.0 and 8.4 will make a parameter group invalid. The common offenders:

| Removed in 8.4 | Replacement |
|---|---|
| `expire_logs_days` | `binlog_expire_logs_seconds` |
| `master_info_repository`, `relay_log_info_repository` | removed (TABLE is the only mode) |
| `slave_*` variables | `replica_*` equivalents |
| `binlog_transaction_dependency_tracking` | removed (WRITESET behavior is built in) |
| `group_replication_ip_whitelist` | `group_replication_ip_allowlist` |

### 4.3 Changed defaults worth reviewing

8.4 changed several InnoDB defaults (e.g. `innodb_adaptive_hash_index` is now `OFF`, `innodb_io_capacity`, `innodb_buffer_pool_instances` and others are auto-tuned differently). If your workload was tuned on 8.0, **explicitly set** the values you rely on in the new parameter group rather than trusting new defaults.

### 4.4 Replication SQL syntax

`SHOW SLAVE STATUS`, `CHANGE MASTER TO`, etc. are gone — use `SHOW REPLICA STATUS`, `CHANGE REPLICATION SOURCE TO`. Grep your tooling, cron jobs, and monitoring scripts for the old syntax.

### 4.5 Automated compatibility check

Run MySQL Shell's upgrade checker remotely against the blue instance — it catches removed features, orphaned objects, reserved-word collisions, and more:

```bash
mysqlsh -h <blue-endpoint> -u admin -p \
  -e "util.checkForServerUpgrade({targetVersion:'8.4'})"
```

Fix every **Error**-level finding before proceeding. Review warnings case by case.

## 5. Phase 1 — Preflight checks

Set your variables once:

```bash
export DB_ID="mydb-prod"
export REGION="eu-west-1"
export TARGET_VERSION="8.4.5"   # pick the latest available, see below
```

**1. Confirm the current version and find valid 8.4 upgrade targets:**

```bash
CURRENT=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --region "$REGION" --query 'DBInstances[0].EngineVersion' --output text)

aws rds describe-db-engine-versions --engine mysql --engine-version "$CURRENT" \
  --region "$REGION" \
  --query 'DBEngineVersions[0].ValidUpgradeTarget[?starts_with(EngineVersion, `8.4`)].EngineVersion' \
  --output table
```

If no 8.4.x target is listed, apply the latest 8.0.x minor version first (a separate, short maintenance event), then re-check.

**2. Confirm binary logging is on** (backup retention ≥ 1):

```bash
aws rds describe-db-instances --db-instance-identifier "$DB_ID" --region "$REGION" \
  --query 'DBInstances[0].{Backups:BackupRetentionPeriod,MultiAZ:MultiAZ,Class:DBInstanceClass,ParamGroup:DBParameterGroups[0].DBParameterGroupName}'
```

**3. Run the SQL-level checks** in [`sql/preflight-checks.sql`](sql/preflight-checks.sql) and the MySQL Shell upgrade checker (section 4.5).

**4. Take a manual snapshot** as an extra safety net:

```bash
aws rds create-db-snapshot --db-instance-identifier "$DB_ID" \
  --db-snapshot-identifier "${DB_ID}-pre-84-upgrade-$(date +%Y%m%d)" --region "$REGION"
```

Or run everything at once: [`scripts/01-preflight.sh`](scripts/01-preflight.sh)

## 6. Phase 2 — Prepare the 8.4 parameter group

Never let the green environment land on the default parameter group.

```bash
# 1. Create the new group
aws rds create-db-parameter-group \
  --db-parameter-group-name "${DB_ID}-mysql84" \
  --db-parameter-group-family mysql8.4 \
  --description "MySQL 8.4 params for ${DB_ID}, migrated from 8.0" \
  --region "$REGION"

# 2. Export your current non-default 8.0 parameters for review
aws rds describe-db-parameters \
  --db-parameter-group-name "<your-current-8.0-group>" \
  --query 'Parameters[?Source==`user`].{Name:ParameterName,Value:ParameterValue}' \
  --output table --region "$REGION"

# 3. Re-apply each parameter that still exists in 8.4 (skip/replace removed ones — see section 4.2)
aws rds modify-db-parameter-group \
  --db-parameter-group-name "${DB_ID}-mysql84" \
  --parameters "ParameterName=max_connections,ParameterValue=2000,ApplyMethod=pending-reboot" \
  --region "$REGION"
```

Helper: [`scripts/02-create-parameter-group.sh`](scripts/02-create-parameter-group.sh)

## 7. Phase 3 — Create the Blue/Green deployment

```bash
SOURCE_ARN=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --region "$REGION" --query 'DBInstances[0].DBInstanceArn' --output text)

aws rds create-blue-green-deployment \
  --blue-green-deployment-name "${DB_ID}-upgrade-84" \
  --source "$SOURCE_ARN" \
  --target-engine-version "$TARGET_VERSION" \
  --target-db-parameter-group-name "${DB_ID}-mysql84" \
  --region "$REGION"
```

Creation takes roughly as long as restoring a snapshot of your database plus the engine upgrade — plan for **tens of minutes to a few hours** on large instances. Monitor:

```bash
aws rds describe-blue-green-deployments \
  --filters Name=blue-green-deployment-name,Values="${DB_ID}-upgrade-84" \
  --region "$REGION" \
  --query 'BlueGreenDeployments[0].{Status:Status,Tasks:Tasks}'
```

Wait until `Status` is **`AVAILABLE`** and every task shows `COMPLETED`. Helper: [`scripts/04-status.sh`](scripts/04-status.sh)

> **From this point until switchover: freeze DDL on blue.** Schema changes, large bulk loads, and `OPTIMIZE TABLE` runs inflate replication lag and can break logical replication on the green side.

## 8. Phase 4 — Validate the green environment

The green instance gets its own temporary endpoint (the instance is named like `mydb-prod-green-abc123`). It is **read-only** — that's intentional.

**Checklist:**

- [ ] Connect to the green endpoint and confirm `SELECT VERSION();` returns 8.4.x
- [ ] Replication healthy and caught up:
  ```sql
  SHOW REPLICA STATUS\G   -- Replica_IO_Running: Yes, Replica_SQL_Running: Yes, Seconds_Behind_Source: 0
  ```
- [ ] Row counts / checksums spot-check on the most important tables
- [ ] Run your application's read-only test suite against the green endpoint
- [ ] Review the upgrade log in RDS logs (`upgrade/PrePatchCompatibility.log` if present) and Events for the green instance
- [ ] `EXPLAIN` your top 10 heaviest queries on green — optimizer behavior can shift between major versions
- [ ] CloudWatch on green: CPU, `ReplicaLag`, FreeableMemory look sane

Soak it for at least one business-day traffic cycle if you can afford the dual-running cost.

### 8.1 Connectivity and load testing from inside the environment (sysbench)

Validate the green environment from where your applications actually run — not from your laptop. If your workloads run on Kubernetes, launch a temporary Ubuntu pod in the same cluster/VPC and test from there; this verifies security groups, routing, and DNS resolution exactly as the application will experience them.

```bash
# 1. Start a throwaway Ubuntu pod in the application's namespace
kubectl run db-upgrade-test --image=ubuntu:24.04 -n <app-namespace> \
  --restart=Never -it --rm -- bash

# 2. Inside the pod: install the tooling
apt-get update && apt-get install -y sysbench mysql-client netcat-openbsd dnsutils

# 3. Reachability checks against the green endpoint
dig +short <green-endpoint>
nc -zv <green-endpoint> 3306
mysql -h <green-endpoint> -u admin -p \
  -e "SELECT VERSION(), @@read_only, @@hostname;"
```

Expected: DNS resolves to a private IP, port 3306 is open, the server reports **8.4.x** and `@@read_only = 1`.

**Benchmarking with sysbench.** Green is read-only, so use this pattern:

```bash
# a) Prepare the sysbench schema on BLUE (writes replicate to green automatically)
sysbench oltp_read_only \
  --mysql-host=<blue-endpoint> --mysql-user=admin --mysql-password='***' \
  --mysql-db=sbtest --tables=8 --table-size=100000 prepare

# b) Baseline run against BLUE (8.0)
sysbench oltp_read_only \
  --mysql-host=<blue-endpoint> --mysql-user=admin --mysql-password='***' \
  --mysql-db=sbtest --tables=8 --table-size=100000 \
  --threads=8 --time=120 --report-interval=10 run

# c) Same run against GREEN (8.4) — compare QPS, latency p95, errors
sysbench oltp_read_only \
  --mysql-host=<green-endpoint> --mysql-user=admin --mysql-password='***' \
  --mysql-db=sbtest --tables=8 --table-size=100000 \
  --threads=8 --time=120 --report-interval=10 run

# d) Cleanup on BLUE once done (the drop replicates to green)
sysbench oltp_read_only \
  --mysql-host=<blue-endpoint> --mysql-user=admin --mysql-password='***' \
  --mysql-db=sbtest --tables=8 cleanup
```

Compare throughput (QPS), average and 95th-percentile latency, and the error count between the two runs. Small variations are normal; a significant regression on green warrants investigation (optimizer changes, parameter group differences) **before** switchover.

> **Cautions:** the `prepare`/`cleanup` steps write to the production (blue) database — use a dedicated `sbtest` schema, keep `--table-size` modest, and run outside peak hours. Never run `oltp_read_write` against either environment during the Blue/Green lifetime; sustained write load inflates replication lag.

## 9. Phase 5 — Switchover

Pick a low-traffic window. Announce it. Then:

```bash
BGD_ID=$(aws rds describe-blue-green-deployments \
  --filters Name=blue-green-deployment-name,Values="${DB_ID}-upgrade-84" \
  --region "$REGION" --query 'BlueGreenDeployments[0].BlueGreenDeploymentIdentifier' --output text)

aws rds switchover-blue-green-deployment \
  --blue-green-deployment-identifier "$BGD_ID" \
  --switchover-timeout 300 \
  --region "$REGION"
```

What RDS does, in order (the **switchover guardrails**):

1. Verifies replication health and waits for green to fully catch up.
2. Blocks new writes on both environments (this is the brief downtime).
3. Swaps the DNS of the endpoints — the production endpoint now points at green.
4. Renames instances: green takes the original name; old blue becomes `mydb-prod-old1`.

If any guardrail fails within `--switchover-timeout` (60–3600 s), RDS **cancels the switchover and rolls back cleanly** — blue keeps serving traffic, nothing is lost, and you can retry.

> **Application note:** connections are dropped at switchover. Apps must reconnect — verify your connection pools retry on failure and don't cache DNS beyond the record TTL (avoid JVM `networkaddress.cache.ttl=-1`!).

Helper: [`scripts/05-switchover.sh`](scripts/05-switchover.sh)

## 10. Phase 6 — Post-switchover validation

- [ ] `SELECT VERSION();` on the **production endpoint** returns 8.4.x
- [ ] Application error rates and latency back to baseline (watch for 15–30 min)
- [ ] Slow query log / Performance Insights: no new heavy hitters
- [ ] Writes succeed (the old blue is now detached and will reject your app anyway, but confirm the app reconnected to the right place: `SELECT @@hostname, @@read_only;`)
- [ ] Scheduled jobs (backups, ETL, monitoring) all point at the production endpoint, not at an instance-specific one
- [ ] **Zero-ETL integration recreated** against the new production environment (see [3.1](#31-zero-etl-integrations-must-be-removed-first)) and the initial re-seed to the analytics target completed

The old blue environment (`*-old1`) still exists, **frozen at the moment of switchover**, and keeps incurring cost. Keep it for an agreed safety period (e.g. 48–72 h), then clean up.

## 11. Phase 7 — Cleanup

```bash
# Delete the blue/green deployment object, KEEPING the old blue instance for now
aws rds delete-blue-green-deployment \
  --blue-green-deployment-identifier "$BGD_ID" --region "$REGION"

# After the safety period, delete the old instance (take a final snapshot)
aws rds delete-db-instance \
  --db-instance-identifier "${DB_ID}-old1" \
  --final-db-snapshot-identifier "${DB_ID}-old1-final" \
  --region "$REGION"
```

Helper: [`scripts/06-cleanup.sh`](scripts/06-cleanup.sh)

## 12. Rollback strategy

| When | How | Data loss |
|---|---|---|
| **Before switchover** | `aws rds delete-blue-green-deployment --delete-target` — green is discarded, production untouched | None |
| **During switchover** | Automatic — guardrail failure cancels and rolls back within the timeout | None |
| **After switchover** | There is **no automatic rollback.** The old blue is frozen at switchover time; writes made to the new 8.4 production after switchover are **not** replicated back. Rolling back means re-pointing to old blue and **losing those writes**, or replaying them manually. | Yes — everything written after switchover |

**Practical consequence:** invest your effort in Phase 4 validation. After a clean switchover plus 30 minutes of healthy metrics, roll *forward* (fix on 8.4), not back.

## 13. Limitations and gotchas

- **Green is read-only.** Don't enable writes on it for testing — you'd break replication.
- **DDL freeze** between green creation and switchover (see Phase 3).
- **Long-running transactions** on blue at switchover time can push you past the timeout — drain batch jobs first.
- **Cross-region read replicas** of the source are not supported.
- **Zero-ETL integrations** block Blue/Green creation — delete before, recreate after (section 3.1), and plan for the analytics re-seed window.
- **Cost:** you pay for two full environments while the deployment exists.
- **In-region read replicas** of blue are copied into green and upgraded too — validate them as well.
- **Don't rename instances or modify the blue instance** (class, storage) while the deployment exists.
- **Aurora MySQL** uses the same Blue/Green API (`--source` is the cluster ARN, parameter group family `aurora-mysql8.4` does not exist — Aurora maps 8.4 differently; check Aurora's supported version mapping before reusing this playbook verbatim).

---

## Helper scripts

| Script | Purpose |
|---|---|
| [`scripts/00-env.sh`](scripts/00-env.sh) | Central config — edit this first |
| [`scripts/01-preflight.sh`](scripts/01-preflight.sh) | All AWS-side preflight checks in one run |
| [`scripts/02-create-parameter-group.sh`](scripts/02-create-parameter-group.sh) | Create the 8.4 parameter group and dump current custom params |
| [`scripts/03-create-blue-green.sh`](scripts/03-create-blue-green.sh) | Take a safety snapshot and create the deployment |
| [`scripts/04-status.sh`](scripts/04-status.sh) | Watch deployment status and tasks |
| [`scripts/05-switchover.sh`](scripts/05-switchover.sh) | Guarded switchover with confirmation prompt |
| [`scripts/06-cleanup.sh`](scripts/06-cleanup.sh) | Delete the deployment, optionally the old blue |
| [`sql/preflight-checks.sql`](sql/preflight-checks.sql) | In-database compatibility checks (auth plugins, etc.) |

All scripts are idempotent where possible and **print what they will do before doing it**.

## License

MIT — use it, adapt it, share it.
