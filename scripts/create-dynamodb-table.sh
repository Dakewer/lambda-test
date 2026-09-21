#!/usr/bin/env bash
# create-dynamodb-table.sh — crea la tabla donde la Lambda guarda los logs.
#
#   pk (S) = <hostname>#<program>      sk (S) = <batch_id>#<linea>
#   GSI event_type-index: event_type + ingested_at  (para consultar sin Scan)
#
# Usage:
#   ./scripts/create-dynamodb-table.sh [table_name]
set -euo pipefail

TABLE_NAME="${1:-${TABLE_NAME:-log-events}}"

aws dynamodb create-table \
  --table-name "${TABLE_NAME}" \
  --billing-mode PAY_PER_REQUEST \
  --attribute-definitions \
    AttributeName=pk,AttributeType=S \
    AttributeName=sk,AttributeType=S \
    AttributeName=event_type,AttributeType=S \
    AttributeName=ingested_at,AttributeType=S \
  --key-schema \
    AttributeName=pk,KeyType=HASH \
    AttributeName=sk,KeyType=RANGE \
  --global-secondary-indexes '[{
    "IndexName": "event_type-index",
    "KeySchema": [
      {"AttributeName": "event_type", "KeyType": "HASH"},
      {"AttributeName": "ingested_at", "KeyType": "RANGE"}
    ],
    "Projection": {"ProjectionType": "ALL"}
  }]' >/dev/null

echo "Creando tabla ${TABLE_NAME}..."
aws dynamodb wait table-exists --table-name "${TABLE_NAME}"
echo "Tabla ${TABLE_NAME} lista."
