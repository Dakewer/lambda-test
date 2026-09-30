#!/usr/bin/env bash
# create-dynamodb-table.sh — crea las tablas DynamoDB "Logs" y "SecurityAlerts".
#
# Ambas tablas comparten el mismo esquema base:
#   pk (S) = <hostname>#<program>      sk (S) = <batch_id>#<linea>
#   GSI event_type-index: event_type + ingested_at  (para consultar sin Scan)
#
# Logs tiene además el GSI last_modified-index, que es el que usa GET /logs?top=N:
#   gsi_pk (S)        = "LOG" para todos los items (partition key fija)
#   last_modified (S) = LastModified del batch en S3 (la hora real en que llegó,
#                       no el timestamp que trae la línea de log)
# Con eso los "últimos N logs" son un Query con Limit=N y ScanIndexForward=false
# en lugar de un Scan de toda la tabla. Una partition key fija concentra todo en
# una partición del índice; para el volumen de esta práctica no es problema.
#
# ¿Por qué ambas tablas comparten el mismo esquema pk/sk?
# 1. Consistencia y simplicidad en Step Functions: la máquina de estados
#    puede usar la misma estructura de parámetros Item en la integración directa
#    arn:aws:states:::dynamodb:putItem tanto para logs normales como para alertas.
# 2. Idempotencia: sk (<batch_id>#<linea>) previene duplicados si un batch se
#    reintenta o se vuelve a procesar.
# 3. Aislamiento: separar SecurityAlerts de Logs permite políticas de retención,
#    alarmas y control de acceso distintos para los eventos sospechosos.
#
# Usage:
#   ./scripts/create-dynamodb-table.sh [logs_table_name] [security_alerts_table_name]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

LOGS_TABLE="${1:-${LOGS_TABLE_NAME}}"
SECURITY_ALERTS_TABLE="${2:-${SECURITY_ALERTS_TABLE_NAME}}"

EVENT_TYPE_GSI='{
  "IndexName": "event_type-index",
  "KeySchema": [
    {"AttributeName": "event_type", "KeyType": "HASH"},
    {"AttributeName": "ingested_at", "KeyType": "RANGE"}
  ],
  "Projection": {"ProjectionType": "ALL"}
}'

LAST_MODIFIED_GSI="{
  \"IndexName\": \"${LOGS_RECENT_INDEX}\",
  \"KeySchema\": [
    {\"AttributeName\": \"gsi_pk\", \"KeyType\": \"HASH\"},
    {\"AttributeName\": \"last_modified\", \"KeyType\": \"RANGE\"}
  ],
  \"Projection\": {\"ProjectionType\": \"ALL\"}
}"

# create_table <nombre> <json de GSIs> [attribute definitions extra...]
create_table() {
  local table_name="$1" gsis="$2"
  shift 2

  if aws dynamodb describe-table --table-name "${table_name}" >/dev/null 2>&1; then
    echo "Tabla ${table_name} ya existe, omitiendo creación."
    return 0
  fi

  echo "Creando tabla ${table_name}..."
  aws dynamodb create-table \
    --table-name "${table_name}" \
    --billing-mode PAY_PER_REQUEST \
    --attribute-definitions \
      AttributeName=pk,AttributeType=S \
      AttributeName=sk,AttributeType=S \
      AttributeName=event_type,AttributeType=S \
      AttributeName=ingested_at,AttributeType=S \
      "$@" \
    --key-schema \
      AttributeName=pk,KeyType=HASH \
      AttributeName=sk,KeyType=RANGE \
    --global-secondary-indexes "${gsis}" >/dev/null

  aws dynamodb wait table-exists --table-name "${table_name}"
  echo "Tabla ${table_name} lista."
}

# Si la tabla Logs ya existía de una parte anterior (sin el GSI por
# LastModified), se le agrega el índice en lugar de recrearla.
ensure_last_modified_gsi() {
  local table_name="$1" status

  status=$(aws dynamodb describe-table --table-name "${table_name}" \
    --query "Table.GlobalSecondaryIndexes[?IndexName=='${LOGS_RECENT_INDEX}'].IndexStatus | [0]" \
    --output text | tr -d '\r')

  if [ "${status}" = "None" ]; then
    echo "Agregando GSI ${LOGS_RECENT_INDEX} a la tabla existente ${table_name}..."
    aws dynamodb update-table --table-name "${table_name}" \
      --attribute-definitions \
        AttributeName=gsi_pk,AttributeType=S \
        AttributeName=last_modified,AttributeType=S \
      --global-secondary-index-updates "[{\"Create\": ${LAST_MODIFIED_GSI}}]" >/dev/null
    status="CREATING"
  fi

  while [ "${status}" != "ACTIVE" ]; do
    echo "Esperando a que el GSI ${LOGS_RECENT_INDEX} quede ACTIVE (estado: ${status})..."
    sleep 10
    status=$(aws dynamodb describe-table --table-name "${table_name}" \
      --query "Table.GlobalSecondaryIndexes[?IndexName=='${LOGS_RECENT_INDEX}'].IndexStatus | [0]" \
      --output text | tr -d '\r')
  done
  echo "GSI ${LOGS_RECENT_INDEX} de ${table_name} listo."
}

create_table "${LOGS_TABLE}" "[${EVENT_TYPE_GSI}, ${LAST_MODIFIED_GSI}]" \
  AttributeName=gsi_pk,AttributeType=S \
  AttributeName=last_modified,AttributeType=S
ensure_last_modified_gsi "${LOGS_TABLE}"

create_table "${SECURITY_ALERTS_TABLE}" "[${EVENT_TYPE_GSI}]"

echo "Tablas DynamoDB creadas exitosamente: ${LOGS_TABLE}, ${SECURITY_ALERTS_TABLE}."
