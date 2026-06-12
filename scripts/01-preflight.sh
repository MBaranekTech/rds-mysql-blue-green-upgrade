#!/usr/bin/env bash
# Preflight checks for the blue/green upgrade. Read-only, safe to run anytime.
set -euo pipefail
source "$(dirname "$0")/00-env.sh"

echo "=== Preflight for ${DB_ID} (${REGION}) ==="

echo
echo "--- Current instance state ---"
aws rds describe-db-instances --db-instance-identifier "$DB_ID" --region "$REGION" \
  --query 'DBInstances[0].{Engine:Engine,Version:EngineVersion,Class:DBInstanceClass,MultiAZ:MultiAZ,Status:DBInstanceStatus,BackupRetention:BackupRetentionPeriod,ParamGroup:DBParameterGroups[0].DBParameterGroupName,ParamApplyStatus:DBParameterGroups[0].ParameterApplyStatus}' \
  --output table

CURRENT=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --region "$REGION" --query 'DBInstances[0].EngineVersion' --output text)

RETENTION=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --region "$REGION" --query 'DBInstances[0].BackupRetentionPeriod' --output text)
if [[ "$RETENTION" -lt 1 ]]; then
  echo "FAIL: BackupRetentionPeriod is 0 — binary logging is off; blue/green requires it." >&2
  exit 1
fi
echo "OK: automated backups enabled (retention ${RETENTION}d) -> binlog active."

echo
echo "--- Valid 8.4 upgrade targets from ${CURRENT} ---"
TARGETS=$(aws rds describe-db-engine-versions --engine mysql --engine-version "$CURRENT" \
  --region "$REGION" \
  --query 'DBEngineVersions[0].ValidUpgradeTarget[?starts_with(EngineVersion, `8.4`)].EngineVersion' \
  --output text)
if [[ -z "$TARGETS" ]]; then
  echo "FAIL: no 8.4.x upgrade target from ${CURRENT}. Apply the latest 8.0.x minor first." >&2
  exit 1
fi
echo "$TARGETS"
if ! grep -qw "$TARGET_VERSION" <<<"$TARGETS"; then
  echo "WARN: TARGET_VERSION=${TARGET_VERSION} is not in the list above — fix 00-env.sh." >&2
fi

echo
echo "--- Cross-region read replicas (must be none) ---"
REPLICAS=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" --region "$REGION" \
  --query 'DBInstances[0].ReadReplicaDBInstanceIdentifiers' --output text)
echo "Read replicas: ${REPLICAS:-none}"
echo "(In-region replicas are fine and will be copied to green; cross-region replicas block blue/green.)"

echo
echo "--- Zero-ETL integrations (must be none on the source) ---"
SOURCE_ARN=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" --region "$REGION" \
  --query 'DBInstances[0].DBInstanceArn' --output text)
INTEGRATIONS=$(aws rds describe-integrations --region "$REGION" \
  --query "Integrations[?SourceArn=='${SOURCE_ARN}'].{Name:IntegrationName,Arn:IntegrationArn,Status:Status}" \
  --output text 2>/dev/null || true)
if [[ -n "$INTEGRATIONS" ]]; then
  echo "FAIL: active zero-ETL integration(s) found on ${DB_ID}:" >&2
  echo "$INTEGRATIONS" >&2
  echo "Record their configuration, delete them before creating the blue/green" >&2
  echo "deployment, and recreate them after switchover (README section 3.1)." >&2
  exit 1
fi
echo "OK: no zero-ETL integrations attached."

echo
echo "=== AWS-side preflight done. Next: run sql/preflight-checks.sql and"
echo "    mysqlsh upgrade checker against the blue endpoint, then 02-create-parameter-group.sh ==="
