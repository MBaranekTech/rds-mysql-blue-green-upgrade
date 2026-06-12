#!/usr/bin/env bash
# Take a safety snapshot, then create the blue/green deployment.
set -euo pipefail
source "$(dirname "$0")/00-env.sh"

SOURCE_ARN=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" --region "$REGION" \
  --query 'DBInstances[0].DBInstanceArn' --output text)

SNAPSHOT_ID="${DB_ID}-pre-84-upgrade-$(date +%Y%m%d-%H%M)"

cat <<EOF
About to:
  1. Create manual snapshot:      ${SNAPSHOT_ID}
  2. Create blue/green deployment ${BGD_NAME}
       source:          ${SOURCE_ARN}
       target version:  ${TARGET_VERSION}
       parameter group: ${NEW_PARAM_GROUP}

NOTE: green doubles instance+storage cost until cleanup. DDL freeze starts NOW.
EOF
read -rp "Proceed? [y/N] " ans
[[ "$ans" == [yY] ]] || { echo "Aborted."; exit 1; }

echo "Creating snapshot ${SNAPSHOT_ID}..."
aws rds create-db-snapshot --db-instance-identifier "$DB_ID" \
  --db-snapshot-identifier "$SNAPSHOT_ID" --region "$REGION" >/dev/null

echo "Creating blue/green deployment ${BGD_NAME}..."
aws rds create-blue-green-deployment \
  --blue-green-deployment-name "$BGD_NAME" \
  --source "$SOURCE_ARN" \
  --target-engine-version "$TARGET_VERSION" \
  --target-db-parameter-group-name "$NEW_PARAM_GROUP" \
  --region "$REGION" \
  --query '{Id:BlueGreenDeployment.BlueGreenDeploymentIdentifier,Status:BlueGreenDeployment.Status}'

echo "Done. Watch progress with: scripts/04-status.sh"
