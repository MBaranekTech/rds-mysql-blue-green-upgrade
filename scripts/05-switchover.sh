#!/usr/bin/env bash
# Guarded switchover: verifies the deployment is AVAILABLE, asks for explicit
# confirmation, then triggers the switchover with a timeout guardrail.
set -euo pipefail
source "$(dirname "$0")/00-env.sh"

BGD_ID=$(aws rds describe-blue-green-deployments \
  --filters Name=blue-green-deployment-name,Values="$BGD_NAME" \
  --region "$REGION" --query 'BlueGreenDeployments[0].BlueGreenDeploymentIdentifier' --output text)
STATUS=$(aws rds describe-blue-green-deployments \
  --blue-green-deployment-identifier "$BGD_ID" --region "$REGION" \
  --query 'BlueGreenDeployments[0].Status' --output text)

if [[ "$STATUS" != "AVAILABLE" ]]; then
  echo "FAIL: deployment status is '${STATUS}', expected AVAILABLE. Not switching over." >&2
  exit 1
fi

cat <<EOF
SWITCHOVER: ${BGD_NAME} (${BGD_ID})
  - Writes will be briefly blocked (target: well under 1 minute).
  - Endpoints swap automatically; apps must reconnect.
  - Guardrail timeout: ${SWITCHOVER_TIMEOUT}s — if green cannot catch up in time,
    RDS cancels and blue keeps serving traffic.

Type the deployment name (${BGD_NAME}) to confirm:
EOF
read -r ans
[[ "$ans" == "$BGD_NAME" ]] || { echo "Confirmation mismatch. Aborted."; exit 1; }

aws rds switchover-blue-green-deployment \
  --blue-green-deployment-identifier "$BGD_ID" \
  --switchover-timeout "$SWITCHOVER_TIMEOUT" \
  --region "$REGION"

echo "Switchover initiated. Watch with scripts/04-status.sh -w and start Phase 6 validation."
