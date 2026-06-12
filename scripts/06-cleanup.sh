#!/usr/bin/env bash
# Cleanup after a successful switchover and safety period.
# Step 1 deletes the deployment object only (keeps the old blue instance).
# Step 2 (explicit flag) deletes the old blue instance with a final snapshot.
set -euo pipefail
source "$(dirname "$0")/00-env.sh"

BGD_ID=$(aws rds describe-blue-green-deployments \
  --filters Name=blue-green-deployment-name,Values="$BGD_NAME" \
  --region "$REGION" --query 'BlueGreenDeployments[0].BlueGreenDeploymentIdentifier' --output text 2>/dev/null || true)

if [[ -n "$BGD_ID" && "$BGD_ID" != "None" ]]; then
  echo "Deleting blue/green deployment ${BGD_ID} (keeping all instances)..."
  read -rp "Proceed? [y/N] " ans
  [[ "$ans" == [yY] ]] || { echo "Aborted."; exit 1; }
  aws rds delete-blue-green-deployment \
    --blue-green-deployment-identifier "$BGD_ID" --region "$REGION" >/dev/null
  echo "Deployment object deleted."
else
  echo "No blue/green deployment named ${BGD_NAME} found (already deleted?)."
fi

if [[ "${1:-}" == "--delete-old-blue" ]]; then
  OLD_ID="${DB_ID}-old1"
  echo
  echo "DELETING old blue instance ${OLD_ID} with final snapshot ${OLD_ID}-final."
  echo "This is irreversible (except via the snapshot)."
  read -rp "Type '${OLD_ID}' to confirm: " ans
  [[ "$ans" == "$OLD_ID" ]] || { echo "Confirmation mismatch. Aborted."; exit 1; }
  aws rds delete-db-instance \
    --db-instance-identifier "$OLD_ID" \
    --final-db-snapshot-identifier "${OLD_ID}-final" \
    --region "$REGION" \
    --query 'DBInstance.DBInstanceStatus'
else
  echo
  echo "Old blue instance kept. After the safety period, run: $0 --delete-old-blue"
fi
