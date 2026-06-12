#!/usr/bin/env bash
# Show blue/green deployment status and task progress. Pass -w to poll every 60s.
set -euo pipefail
source "$(dirname "$0")/00-env.sh"

show() {
  aws rds describe-blue-green-deployments \
    --filters Name=blue-green-deployment-name,Values="$BGD_NAME" \
    --region "$REGION" \
    --query 'BlueGreenDeployments[0].{Status:Status,Source:Source,Target:Target,Tasks:Tasks[].{Name:Name,Status:Status}}'
}

if [[ "${1:-}" == "-w" ]]; then
  while true; do
    clear; date; show
    STATUS=$(aws rds describe-blue-green-deployments \
      --filters Name=blue-green-deployment-name,Values="$BGD_NAME" \
      --region "$REGION" --query 'BlueGreenDeployments[0].Status' --output text)
    [[ "$STATUS" == "AVAILABLE" ]] && { echo; echo "Green is AVAILABLE — start Phase 4 validation."; break; }
    sleep 60
  done
else
  show
fi
