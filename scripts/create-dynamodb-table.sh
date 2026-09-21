#!/usr/bin/env bash
# create-dynamodb-table.sh — crea las tablas DynamoDB "Logs" y "SecurityAlerts".
#
# Ambas tablas comparten el mismo esquema:
#   pk (S) = <hostname>#<program>      sk (S) = <batch_id>#<linea>
#   GSI event_type-index: event_type + ingested_at  (para consultar sin Scan)
#
# ¿Por qué ambas tablas comparten el mismo esquema pk/sk?
# 1. Consistencia y simplicidad en Step Functions: la máquina de estados
#    puede usar la misma estructura de parámetros Item en la integración directa
#    arn:aws:states:::dynamodb:putItem tanto para logs normales como para alertas.
# 2. Idempotencia y particionamiento óptimo: pk (<hostname>#<program>) agrupa
#    por servicio emisor y sk (<batch_id>#<linea>) garantiza orden y previene
#    duplicados si un batch se reintenta o se vuelve a procesar.
# 3. Consultas eficientes: el GSI event_type-index permite consultar por tipo
#    de evento (p. ej. break_in_attempt, invalid_user) y rango temporal en ambas tablas.
# 4. Aislamiento físico y seguridad: separar SecurityAlerts de Logs permite
#    políticas de retención prolongada, alarmas dedicadas y control de acceso
#    más estricto sobre eventos sospechosos sin sobrecargar la tabla de logs generales.
#
# Usage:
#   ./scripts/create-dynamodb-table.sh [logs_table_name] [security_alerts_table_name]
set -euo pipefail

LOGS_TABLE="${1:-${LOGS_TABLE_NAME:-Logs}}"
SECURITY_ALERTS_TABLE="${2:-${SECURITY_ALERTS_TABLE_NAME:-SecurityAlerts}}"

create_table() {
  local table_name="$1"

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

  aws dynamodb wait table-exists --table-name "${table_name}"
  echo "Tabla ${table_name} lista."
}

create_table "${LOGS_TABLE}"
create_table "${SECURITY_ALERTS_TABLE}"

echo "Tablas DynamoDB creadas exitosamente: ${LOGS_TABLE}, ${SECURITY_ALERTS_TABLE}."
