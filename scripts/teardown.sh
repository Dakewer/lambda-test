#!/usr/bin/env bash
# teardown.sh — elimina todos los recursos creados por los scripts del proyecto:
# regla y target de EventBridge, Step Functions state machine, funciones Lambda,
# roles IAM (solo si fueron creados por este proyecto), tablas DynamoDB,
# notificaciones y bucket S3 (incluyendo su contenido), y artefactos de build/.
#
# Usage:
#   ./scripts/teardown.sh
set -euo pipefail

# Variables de la parte 3 (Step Functions) con mismos defaults que deploy-state-machine.sh
STATE_MACHINE_NAME="${STATE_MACHINE_NAME:-log-processing-state-machine}"
LAMBDA_FUNCTION_NAME="${LAMBDA_FUNCTION_NAME:-parse-batch}"
BUCKET_NAME="${BUCKET_NAME:-logging-bucket-1321}"
LOGS_TABLE_NAME="${LOGS_TABLE_NAME:-Logs}"
SECURITY_ALERTS_TABLE_NAME="${SECURITY_ALERTS_TABLE_NAME:-SecurityAlerts}"

PARSE_BATCH_ROLE_NAME="${PARSE_BATCH_ROLE_NAME:-${LAMBDA_ROLE_NAME:-parse-batch-lambda-role}}"
SFN_ROLE_NAME="${SFN_ROLE_NAME:-step-functions-log-processing-role}"
EB_RULE_NAME="${EB_RULE_NAME:-s3-log-processing-rule}"
EB_ROLE_NAME="${EB_ROLE_NAME:-eventbridge-step-functions-role}"

# Variables de la parte 2 (Lambda directa)
FUNCTION_NAME="${FUNCTION_NAME:-log-processing}"
ROLE_NAME="${ROLE_NAME:-log-processing-lambda-role}"
TABLE_NAME="${TABLE_NAME:-log-events}"

BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../build"
ROLE_MARKER="${BUILD_DIR}/.role-created-by-script"
PARSE_BATCH_ROLE_MARKER="${BUILD_DIR}/.parse-batch-role-created-by-script"
SFN_ROLE_MARKER="${BUILD_DIR}/.sfn-role-created-by-script"
EB_ROLE_MARKER="${BUILD_DIR}/.eb-role-created-by-script"

echo "== Eliminando regla y target de EventBridge =="
aws events remove-targets --rule "${EB_RULE_NAME}" --ids "StepFunctionsTarget" 2>/dev/null || true
aws events delete-rule --name "${EB_RULE_NAME}" 2>/dev/null \
  && echo "Eliminada regla EventBridge ${EB_RULE_NAME}." || echo "Regla EventBridge ${EB_RULE_NAME} no encontrada, omitiendo."

echo "== Eliminando State Machine de Step Functions =="
STATE_MACHINE_ARN=$(aws stepfunctions list-state-machines \
  --query "stateMachines[?name=='${STATE_MACHINE_NAME}'].stateMachineArn" \
  --output text 2>/dev/null || true)

if [ -n "${STATE_MACHINE_ARN}" ] && [ "${STATE_MACHINE_ARN}" != "None" ]; then
  aws stepfunctions delete-state-machine --state-machine-arn "${STATE_MACHINE_ARN}" >/dev/null 2>&1 \
    && echo "Eliminada State Machine ${STATE_MACHINE_NAME}." || echo "Error al eliminar State Machine ${STATE_MACHINE_NAME}."
else
  echo "State Machine ${STATE_MACHINE_NAME} no encontrada, omitiendo."
fi

echo "== Eliminando notificaciones del bucket S3 =="
aws s3api put-bucket-notification-configuration --bucket "${BUCKET_NAME}" \
  --notification-configuration '{}' 2>/dev/null || true

echo "== Eliminando funciones Lambda =="
aws lambda delete-function --function-name "${LAMBDA_FUNCTION_NAME}" 2>/dev/null \
  && echo "Eliminada Lambda ${LAMBDA_FUNCTION_NAME}." || echo "Lambda ${LAMBDA_FUNCTION_NAME} no encontrada, omitiendo."

aws lambda delete-function --function-name "${FUNCTION_NAME}" 2>/dev/null \
  && echo "Eliminada Lambda ${FUNCTION_NAME}." || echo "Lambda ${FUNCTION_NAME} no encontrada, omitiendo."

echo "== Eliminando roles IAM creados por el proyecto =="
# Solo se eliminan roles si el archivo marcador correspondiente confirma
# que fueron creados por este proyecto. Nunca se borran roles preexistentes (como LabRole).

if [ -f "${PARSE_BATCH_ROLE_MARKER}" ] && [ "$(cat "${PARSE_BATCH_ROLE_MARKER}")" = "${PARSE_BATCH_ROLE_NAME}" ]; then
  echo "Eliminando políticas y rol IAM de Lambda parse-batch (${PARSE_BATCH_ROLE_NAME})..."
  aws iam delete-role-policy --role-name "${PARSE_BATCH_ROLE_NAME}" \
    --policy-name "parse-batch-s3-access" 2>/dev/null || true
  aws iam detach-role-policy --role-name "${PARSE_BATCH_ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" 2>/dev/null || true
  aws iam delete-role --role-name "${PARSE_BATCH_ROLE_NAME}" 2>/dev/null \
    && echo "Eliminado rol ${PARSE_BATCH_ROLE_NAME}." || echo "Rol ${PARSE_BATCH_ROLE_NAME} no encontrado, omitiendo."
else
  echo "Rol ${PARSE_BATCH_ROLE_NAME} no fue creado por este proyecto (o falta marcador), se omite."
fi

if [ -f "${SFN_ROLE_MARKER}" ] && [ "$(cat "${SFN_ROLE_MARKER}")" = "${SFN_ROLE_NAME}" ]; then
  echo "Eliminando políticas y rol IAM de Step Functions (${SFN_ROLE_NAME})..."
  aws iam delete-role-policy --role-name "${SFN_ROLE_NAME}" \
    --policy-name "step-functions-access" 2>/dev/null || true
  aws iam delete-role --role-name "${SFN_ROLE_NAME}" 2>/dev/null \
    && echo "Eliminado rol ${SFN_ROLE_NAME}." || echo "Rol ${SFN_ROLE_NAME} no encontrado, omitiendo."
else
  echo "Rol ${SFN_ROLE_NAME} no fue creado por este proyecto (o falta marcador), se omite."
fi

if [ -f "${EB_ROLE_MARKER}" ] && [ "$(cat "${EB_ROLE_MARKER}")" = "${EB_ROLE_NAME}" ]; then
  echo "Eliminando políticas y rol IAM de EventBridge (${EB_ROLE_NAME})..."
  aws iam delete-role-policy --role-name "${EB_ROLE_NAME}" \
    --policy-name "eventbridge-invoke-sfn" 2>/dev/null || true
  aws iam delete-role --role-name "${EB_ROLE_NAME}" 2>/dev/null \
    && echo "Eliminado rol ${EB_ROLE_NAME}." || echo "Rol ${EB_ROLE_NAME} no encontrado, omitiendo."
else
  echo "Rol ${EB_ROLE_NAME} no fue creado por este proyecto (o falta marcador), se omite."
fi

if [ -f "${ROLE_MARKER}" ] && [ "$(cat "${ROLE_MARKER}")" = "${ROLE_NAME}" ]; then
  echo "Eliminando políticas y rol IAM de Lambda log-processing (${ROLE_NAME})..."
  aws iam delete-role-policy --role-name "${ROLE_NAME}" \
    --policy-name "logging-bucket-access" 2>/dev/null || true
  aws iam detach-role-policy --role-name "${ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" 2>/dev/null || true
  aws iam delete-role --role-name "${ROLE_NAME}" 2>/dev/null \
    && echo "Eliminado rol ${ROLE_NAME}." || echo "Rol ${ROLE_NAME} no encontrado, omitiendo."
else
  echo "Rol ${ROLE_NAME} no fue creado por este proyecto (o falta marcador), se omite."
fi

echo "== Eliminando tablas DynamoDB =="
for table in "${LOGS_TABLE_NAME}" "${SECURITY_ALERTS_TABLE_NAME}" "${TABLE_NAME}"; do
  aws dynamodb delete-table --table-name "${table}" >/dev/null 2>&1 \
    && echo "Eliminada tabla ${table}." || echo "Tabla ${table} no encontrada, omitiendo."
done

echo "== Vaciando y eliminando bucket S3 =="
aws s3 rm "s3://${BUCKET_NAME}" --recursive 2>/dev/null || true
aws s3api delete-bucket --bucket "${BUCKET_NAME}" 2>/dev/null \
  && echo "Eliminado bucket ${BUCKET_NAME}." || echo "Bucket ${BUCKET_NAME} no encontrado, omitiendo."

echo "== Limpiando artefactos locales de build =="
rm -rf "${BUILD_DIR}"

echo "Teardown completado exitosamente."
