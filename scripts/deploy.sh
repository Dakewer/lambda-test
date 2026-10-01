#!/usr/bin/env bash
# deploy.sh — crea toda la infraestructura en orden:
#   1. bucket S3                      (create-s3-bucket.sh)
#   2. tablas Logs y SecurityAlerts   (create-dynamodb-table.sh)
#   3. Lambda parse-batch, Step Functions y regla EventBridge (deploy-state-machine.sh)
#   4. Lambdas get-alerts / get-logs y HTTP API               (deploy-api.sh)
#
# Usage:
#   ./scripts/deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
# Los scripts hijos heredan la cuenta/región/bucket sin volver a consultarlas.
export ACCOUNT_ID BUCKET_NAME

bash "${SCRIPT_DIR}/create-s3-bucket.sh"
bash "${SCRIPT_DIR}/create-dynamodb-table.sh"
bash "${SCRIPT_DIR}/deploy-state-machine.sh"
bash "${SCRIPT_DIR}/deploy-api.sh"

echo
echo "== Infraestructura lista =="
echo "Bucket:   s3://${BUCKET_NAME}"
echo "API:      $(cat "${SCRIPT_DIR}/../build/api-endpoint.txt")"
echo
echo "OJO: en un bucket recién creado, S3 tarda unos minutos (~5) en empezar a"
echo "mandar eventos a EventBridge; los batches que se suban antes no disparan"
echo "la state machine. Espera un poco antes del siguiente paso:"
echo "  ./scripts/start_logging.sh 30"
