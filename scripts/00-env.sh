#!/usr/bin/env bash
# Central configuration for the MySQL 8.0 -> 8.4 blue/green upgrade.
# Edit these values, then source this file or let the other scripts source it.

export DB_ID="${DB_ID:-mydb-prod}"                      # RDS instance identifier (blue)
export REGION="${REGION:-eu-west-1}"
export TARGET_VERSION="${TARGET_VERSION:-8.4.5}"        # confirm with 01-preflight.sh
export BGD_NAME="${BGD_NAME:-${DB_ID}-upgrade-84}"      # blue/green deployment name
export NEW_PARAM_GROUP="${NEW_PARAM_GROUP:-${DB_ID}-mysql84}"
export SWITCHOVER_TIMEOUT="${SWITCHOVER_TIMEOUT:-300}"  # seconds, 60-3600
