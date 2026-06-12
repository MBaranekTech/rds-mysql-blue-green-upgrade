-- In-database preflight checks for MySQL 8.0 -> 8.4 upgrade.
-- Run against the BLUE (production) endpoint with a privileged user.
-- All checks are read-only.

-- 1. Accounts still on mysql_native_password (disabled by default in 8.4).
--    Every row here must be migrated to caching_sha2_password BEFORE the upgrade,
--    and the owning application's driver verified to support it.
SELECT user, host, plugin
FROM mysql.user
WHERE plugin = 'mysql_native_password'
ORDER BY user, host;

-- 2. Current authentication-related settings for reference.
SHOW VARIABLES LIKE 'default_authentication_plugin';

-- 3. Long-running transactions (must be drained before switchover; check again
--    right before Phase 5).
SELECT trx_id, trx_started, trx_mysql_thread_id,
       TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS runtime_s
FROM information_schema.innodb_trx
WHERE TIMESTAMPDIFF(SECOND, trx_started, NOW()) > 60
ORDER BY trx_started;

-- 4. Open XA transactions (block clean switchover).
XA RECOVER;

-- 5. Tables without a primary key — logical replication to green is far slower
--    and riskier for these. Strongly consider adding PKs first.
SELECT t.table_schema, t.table_name
FROM information_schema.tables t
LEFT JOIN information_schema.table_constraints c
  ON  c.table_schema   = t.table_schema
  AND c.table_name     = t.table_name
  AND c.constraint_type = 'PRIMARY KEY'
WHERE t.table_type = 'BASE TABLE'
  AND t.table_schema NOT IN ('mysql','sys','information_schema','performance_schema')
  AND c.constraint_name IS NULL
ORDER BY t.table_schema, t.table_name;

-- 6. Stored programs / views referencing removed replication syntax is not
--    detectable via SQL alone — run the MySQL Shell upgrade checker too:
--    mysqlsh -h <blue-endpoint> -u admin -p \
--      -e "util.checkForServerUpgrade({targetVersion:'8.4'})"
