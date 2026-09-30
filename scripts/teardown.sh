#!/usr/bin/env bash
# teardown.sh — elimina todos los recursos creados por los scripts del proyecto:
# regla y target de EventBridge, Step Functions state machine,
# funciones Lambda (y sus log groups), roles IAM (solo si fueron creados por
# este proyecto), tablas DynamoDB, notificaciones y bucket S3 (incluyendo su
# contenido), y artefactos de build/. Al final verifica que ya no exista nada.
#
# Usage:
#   ./scripts/teardown.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# Recursos de la parte 2 (Lambda directa), por si se desplegaron.
FUNCTION_NAME="${FUNCTION_NAME:-log-processing}"
ROLE_NAME="${ROLE_NAME:-log-processing-lambda-role}"
TABLE_NAME="${TABLE_NAME:-log-events}"

BUILD_DIR="${SCRIPT_DIR}/../build"
LAMBDAS=("${LAMBDA_FUNCTION_NAME}" "${FUNCTION_NAME}")
TABLES=("${LOGS_TABLE_NAME}" "${SECURITY_ALERTS_TABLE_NAME}" "${TABLE_NAME}")

echo "Cuenta: ${ACCOUNT_ID}, Región: ${AWS_REGION}"

echo "== Eliminando regla y target de EventBridge =="
aws events remove-targets --rule "${EB_RULE_NAME}" --ids "StepFunctionsTarget" >/dev/null 2>&1 || true
aws events delete-rule --name "${EB_RULE_NAME}" 2>/dev/null \
  && echo "Eliminada regla EventBridge ${EB_RULE_NAME}." || echo "Regla EventBridge ${EB_RULE_NAME} no encontrada, omitiendo."

echo "== Eliminando State Machine de Step Functions =="
STATE_MACHINE_ARN=$(aws stepfunctions list-state-machines \
  --query "stateMachines[?name=='${STATE_MACHINE_NAME}'].stateMachineArn | [0]" \
  --output text 2>/dev/null || true)

if [ -n "${STATE_MACHINE_ARN}" ] && [ "${STATE_MACHINE_ARN}" != "None" ]; then
  aws stepfunctions delete-state-machine --state-machine-arn "${STATE_MACHINE_ARN}" >/dev/null 2>&1 \
    && echo "Eliminando State Machine ${STATE_MACHINE_NAME}..." || echo "Error al eliminar State Machine ${STATE_MACHINE_NAME}."
  # El borrado es asíncrono (queda en DELETING); se espera hasta ~60s.
  for _ in $(seq 1 30); do
    aws stepfunctions describe-state-machine --state-machine-arn "${STATE_MACHINE_ARN}" >/dev/null 2>&1 || break
    sleep 2
  done
  echo "Eliminada State Machine ${STATE_MACHINE_NAME}."
else
  echo "State Machine ${STATE_MACHINE_NAME} no encontrada, omitiendo."
fi

echo "== Eliminando notificaciones del bucket S3 =="
aws s3api put-bucket-notification-configuration --bucket "${BUCKET_NAME}" \
  --notification-configuration '{}' 2>/dev/null || true

echo "== Eliminando funciones Lambda y sus log groups =="
for fn in "${LAMBDAS[@]}"; do
  aws lambda delete-function --function-name "${fn}" 2>/dev/null \
    && echo "Eliminada Lambda ${fn}." || echo "Lambda ${fn} no encontrada, omitiendo."
  aws logs delete-log-group --log-group-name "/aws/lambda/${fn}" 2>/dev/null \
    && echo "Eliminado log group /aws/lambda/${fn}." || true
done

echo "== Eliminando roles IAM creados por el proyecto =="
# Solo se eliminan roles si el archivo marcador correspondiente confirma
# que fueron creados por este proyecto. Nunca se borran roles preexistentes (como LabRole).
# delete_role <marcador> <rol> <inline policy> [managed policy]
delete_role() {
  local marker="${BUILD_DIR}/$1" role="$2" inline_policy="$3" managed_policy="${4:-}"

  if [ ! -f "${marker}" ] || [ "$(cat "${marker}")" != "${role}" ]; then
    echo "Rol ${role} no fue creado por este proyecto (o falta marcador), se omite."
    return 0
  fi

  aws iam delete-role-policy --role-name "${role}" --policy-name "${inline_policy}" 2>/dev/null || true
  if [ -n "${managed_policy}" ]; then
    aws iam detach-role-policy --role-name "${role}" --policy-arn "${managed_policy}" 2>/dev/null || true
  fi
  aws iam delete-role --role-name "${role}" 2>/dev/null \
    && echo "Eliminado rol ${role}." || echo "Rol ${role} no encontrado, omitiendo."
}

BASIC_EXECUTION="arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
delete_role .parse-batch-role-created-by-script "${LAMBDA_ROLE_NAME}" parse-batch-s3-access "${BASIC_EXECUTION}"
delete_role .sfn-role-created-by-script "${SFN_ROLE_NAME}" step-functions-access
delete_role .eb-role-created-by-script "${EB_ROLE_NAME}" eventbridge-invoke-sfn
delete_role .role-created-by-script "${ROLE_NAME}" logging-bucket-access "${BASIC_EXECUTION}"

echo "== Eliminando tablas DynamoDB =="
for table in "${TABLES[@]}"; do
  if aws dynamodb delete-table --table-name "${table}" >/dev/null 2>&1; then
    echo "Eliminando tabla ${table}..."
    aws dynamodb wait table-not-exists --table-name "${table}"
    echo "Eliminada tabla ${table}."
  else
    echo "Tabla ${table} no encontrada, omitiendo."
  fi
done

echo "== Vaciando y eliminando bucket S3 =="
aws s3 rm "s3://${BUCKET_NAME}" --recursive --only-show-errors 2>/dev/null || true
aws s3api delete-bucket --bucket "${BUCKET_NAME}" 2>/dev/null \
  && echo "Eliminado bucket ${BUCKET_NAME}." || echo "Bucket ${BUCKET_NAME} no encontrado, omitiendo."

echo "== Limpiando artefactos locales de build =="
rm -rf "${BUILD_DIR}"

# -----------------------------------------------------------------------------
# Verificación: consulta cada recurso y confirma que ya no existe.
# -----------------------------------------------------------------------------
echo
echo "== Verificación =="
REMAINING=0
check_gone() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  [X] ${label} todavía existe"
    REMAINING=$((REMAINING + 1))
  else
    echo "  [ok] ${label} eliminado"
  fi
}
# `aws ... --query` regresa "None"/vacío con exit 0 cuando no hay resultados,
# así que se convierte en exit != 0 para check_gone.
exists_query() {
  local out
  out=$("$@" --output text 2>/dev/null) || return 1
  [ -n "${out}" ] && [ "${out}" != "None" ]
}

check_gone "Bucket s3://${BUCKET_NAME}" aws s3api head-bucket --bucket "${BUCKET_NAME}"
for table in "${LOGS_TABLE_NAME}" "${SECURITY_ALERTS_TABLE_NAME}"; do
  check_gone "Tabla DynamoDB ${table}" aws dynamodb describe-table --table-name "${table}"
done
check_gone "Lambda ${LAMBDA_FUNCTION_NAME}" aws lambda get-function --function-name "${LAMBDA_FUNCTION_NAME}"
check_gone "State Machine ${STATE_MACHINE_NAME}" exists_query aws stepfunctions list-state-machines \
  --query "stateMachines[?name=='${STATE_MACHINE_NAME}'].name | [0]"
check_gone "Regla EventBridge ${EB_RULE_NAME}" aws events describe-rule --name "${EB_RULE_NAME}"

if [ "${REMAINING}" -eq 0 ]; then
  echo "Teardown completado: todos los recursos fueron eliminados."
else
  echo "Teardown terminó, pero quedan ${REMAINING} recurso(s); revisa arriba." >&2
  exit 1
fi
