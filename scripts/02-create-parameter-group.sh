#!/usr/bin/env bash
# Create the mysql8.4 parameter group and dump the current custom (user-set)
# parameters so you can port them over consciously.
set -euo pipefail
source "$(dirname "$0")/00-env.sh"

CURRENT_PG=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" --region "$REGION" \
  --query 'DBInstances[0].DBParameterGroups[0].DBParameterGroupName' --output text)

echo "Creating parameter group ${NEW_PARAM_GROUP} (family mysql8.4)..."
aws rds create-db-parameter-group \
  --db-parameter-group-name "$NEW_PARAM_GROUP" \
  --db-parameter-group-family mysql8.4 \
  --description "MySQL 8.4 params for ${DB_ID}, migrated from ${CURRENT_PG}" \
  --region "$REGION" >/dev/null \
  || echo "(already exists, continuing)"

echo
echo "--- Custom (user-set) parameters in ${CURRENT_PG} — port these manually ---"
echo "--- NOTE: skip parameters removed in 8.4 (expire_logs_days, master_info_repository,"
echo "---       relay_log_info_repository, slave_*, binlog_transaction_dependency_tracking) ---"
aws rds describe-db-parameters \
  --db-parameter-group-name "$CURRENT_PG" --region "$REGION" \
  --query 'Parameters[?Source==`user`].{Name:ParameterName,Value:ParameterValue,Apply:ApplyMethod}' \
  --output table

cat <<EOF

To apply a parameter to the new group:

  aws rds modify-db-parameter-group \\
    --db-parameter-group-name ${NEW_PARAM_GROUP} \\
    --parameters "ParameterName=<name>,ParameterValue=<value>,ApplyMethod=pending-reboot" \\
    --region ${REGION}
EOF
