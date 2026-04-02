#!/usr/bin/env bash
# Generate a unique MLflow experiment name for this eval session.
#
# Usage:
#   source deploy/new-eval-session.sh        # set env vars
#   # Then start the agent and run tests — both share the same experiment.
#
# The experiment name format: <prefix>-<YYYYMMDD-HHMMSS>
# Override the prefix with MLFLOW_EXPERIMENT_PREFIX (default: "eval").

set -euo pipefail

: "${MLFLOW_TRACKING_URI:=http://localhost:5000}"
: "${MLFLOW_EXPERIMENT_PREFIX:=eval}"

TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")
EXPERIMENT_NAME="${MLFLOW_EXPERIMENT_PREFIX}-${TIMESTAMP}"

export MLFLOW_TRACKING_URI
export MLFLOW_EXPERIMENT_NAME="$EXPERIMENT_NAME"

echo "MLflow session:"
echo "  MLFLOW_TRACKING_URI=$MLFLOW_TRACKING_URI"
echo "  MLFLOW_EXPERIMENT_NAME=$MLFLOW_EXPERIMENT_NAME"
echo ""
echo "Start the agent and run tests in this shell to share the experiment."
