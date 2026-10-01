#!/usr/bin/env bash
# deploy-api.sh — empaqueta y despliega las Lambdas de consulta y crea el
# HTTP API de API Gateway, con una Lambda por endpoint:
#
#   GET /alerts       -> get-alerts  (Scan de SecurityAlerts)
#   GET /logs?top=N   -> get-logs    (Query al GSI last_modified-index de Logs)
#
# Es idempotente: si el API, las rutas o las Lambdas ya existen, los
# actualiza en lugar de duplicarlos.
#
# Usage:
#   ./scripts/deploy-api.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

RUNTIME="python3.12"
HANDLER="lambda_function.lambda_handler"
TIMEOUT=10
MEMORY=128

ROOT_DIR="${SCRIPT_DIR}/.."
BUILD_DIR="${ROOT_DIR}/build"
mkdir -p "${BUILD_DIR}"

echo "Cuenta: ${ACCOUNT_ID}, Región: ${AWS_REGION}"

# -----------------------------------------------------------------------------
# 1. Rol IAM compartido por las dos Lambdas de consulta (solo lectura)
# -----------------------------------------------------------------------------
echo "== Verificando rol IAM de las Lambdas del API (${API_ROLE_NAME}) =="
if aws iam get-role --role-name "${API_ROLE_NAME}" >/dev/null 2>&1; then
  echo "Rol ${API_ROLE_NAME} ya existe, reutilizando."
else
  echo "Intentando crear rol ${API_ROLE_NAME}..."
  if aws iam create-role --role-name "${API_ROLE_NAME}" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "lambda.amazonaws.com"},
        "Action": "sts:AssumeRole"
      }]
    }' >/dev/null 2>/tmp/create-api-role.err; then
    echo "${API_ROLE_NAME}" > "${BUILD_DIR}/.api-role-created-by-script"

    aws iam attach-role-policy --role-name "${API_ROLE_NAME}" \
      --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

    aws iam put-role-policy --role-name "${API_ROLE_NAME}" \
      --policy-name "logging-api-dynamodb-read" \
      --policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [
          {
            \"Effect\": \"Allow\",
            \"Action\": [\"dynamodb:Scan\"],
            \"Resource\": \"arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/${SECURITY_ALERTS_TABLE_NAME}\"
          },
          {
            \"Effect\": \"Allow\",
            \"Action\": [\"dynamodb:Query\"],
            \"Resource\": \"arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/${LOGS_TABLE_NAME}/index/${LOGS_RECENT_INDEX}\"
          }
        ]
      }"
    echo "Esperando propagación del rol IAM..."
    sleep 10
  else
    explain_role_error "${API_ROLE_NAME}" /tmp/create-api-role.err
    if aws iam get-role --role-name "${FALLBACK_ROLE_NAME}" >/dev/null 2>&1; then
      echo "Usando rol fallback '${FALLBACK_ROLE_NAME}'."
      API_ROLE_NAME="${FALLBACK_ROLE_NAME}"
    else
      echo "ERROR: No hay rol IAM utilizable para las Lambdas del API." >&2
      exit 1
    fi
  fi
fi
API_ROLE_ARN=$(aws iam get-role --role-name "${API_ROLE_NAME}" --query 'Role.Arn' --output text)

# -----------------------------------------------------------------------------
# 2. Lambdas get-alerts y get-logs
# -----------------------------------------------------------------------------
# deploy_lambda <function_name> <src_dir> <environment>
# Deja el ARN de la función en FUNCTION_ARN.
deploy_lambda() {
  local function_name="$1" src_dir="$2" environment="$3"
  local pkg_dir="${BUILD_DIR}/${function_name}-pkg"
  local zip_file="${BUILD_DIR}/${function_name}.zip"

  echo "== Empaquetando y desplegando Lambda ${function_name} =="
  rm -rf "${pkg_dir}" "${zip_file}"
  mkdir -p "${pkg_dir}"
  cp "${src_dir}/lambda_function.py" "${pkg_dir}/"
  (cd "${pkg_dir}" && zip -rq "${zip_file}" .)

  if aws lambda get-function --function-name "${function_name}" >/dev/null 2>&1; then
    aws lambda update-function-code --function-name "${function_name}" \
      --zip-file "fileb://${zip_file}" >/dev/null
    aws lambda wait function-updated --function-name "${function_name}"
    aws lambda update-function-configuration --function-name "${function_name}" \
      --environment "${environment}" >/dev/null
    aws lambda wait function-updated --function-name "${function_name}"
    echo "Función Lambda ${function_name} actualizada."
  else
    aws lambda create-function --function-name "${function_name}" \
      --runtime "${RUNTIME}" \
      --role "${API_ROLE_ARN}" \
      --handler "${HANDLER}" \
      --timeout "${TIMEOUT}" \
      --memory-size "${MEMORY}" \
      --environment "${environment}" \
      --zip-file "fileb://${zip_file}" >/dev/null
    aws lambda wait function-active --function-name "${function_name}"
    echo "Función Lambda ${function_name} creada."
  fi

  FUNCTION_ARN=$(aws lambda get-function --function-name "${function_name}" \
    --query 'Configuration.FunctionArn' --output text)
}

deploy_lambda "${ALERTS_FUNCTION_NAME}" "${ROOT_DIR}/src/get-alerts" \
  "Variables={SECURITY_ALERTS_TABLE_NAME=${SECURITY_ALERTS_TABLE_NAME}}"
ALERTS_FUNCTION_ARN="${FUNCTION_ARN}"

deploy_lambda "${LOGS_FUNCTION_NAME}" "${ROOT_DIR}/src/get-logs" \
  "Variables={LOGS_TABLE_NAME=${LOGS_TABLE_NAME},LOGS_RECENT_INDEX=${LOGS_RECENT_INDEX}}"
LOGS_FUNCTION_ARN="${FUNCTION_ARN}"

# -----------------------------------------------------------------------------
# 3. HTTP API
# -----------------------------------------------------------------------------
echo "== Configurando HTTP API ${API_NAME} =="
API_ID=$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text)

if [ -z "${API_ID}" ] || [ "${API_ID}" = "None" ]; then
  API_ID=$(aws apigatewayv2 create-api --name "${API_NAME}" --protocol-type HTTP \
    --description "Consulta de logs y alertas de seguridad" \
    --query ApiId --output text)
  echo "HTTP API creado: ${API_ID}"
else
  echo "HTTP API ${API_NAME} ya existe (${API_ID}), reutilizando."
fi

# ensure_route <route_key> <function_name> <function_arn> <path>
# Crea (o re-apunta) la integración Lambda proxy y la ruta, y le da permiso a
# API Gateway de invocar la función.
ensure_route() {
  local route_key="$1" function_name="$2" function_arn="$3" path="$4"
  local integration_id route_id

  integration_id=$(aws apigatewayv2 get-integrations --api-id "${API_ID}" \
    --query "Items[?IntegrationUri=='${function_arn}'].IntegrationId | [0]" --output text)
  if [ -z "${integration_id}" ] || [ "${integration_id}" = "None" ]; then
    integration_id=$(aws apigatewayv2 create-integration --api-id "${API_ID}" \
      --integration-type AWS_PROXY \
      --integration-uri "${function_arn}" \
      --payload-format-version "2.0" \
      --query IntegrationId --output text)
  fi

  route_id=$(aws apigatewayv2 get-routes --api-id "${API_ID}" \
    --query "Items[?RouteKey=='${route_key}'].RouteId | [0]" --output text)
  if [ -z "${route_id}" ] || [ "${route_id}" = "None" ]; then
    aws apigatewayv2 create-route --api-id "${API_ID}" \
      --route-key "${route_key}" --target "integrations/${integration_id}" >/dev/null
  else
    aws apigatewayv2 update-route --api-id "${API_ID}" --route-id "${route_id}" \
      --target "integrations/${integration_id}" >/dev/null
  fi

  # Falla si el permiso ya existe de una corrida anterior; eso está bien.
  aws lambda add-permission --function-name "${function_name}" \
    --statement-id "apigateway-${API_ID}" \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${AWS_REGION}:${ACCOUNT_ID}:${API_ID}/*/*${path}" \
    >/dev/null 2>&1 || true

  echo "Ruta '${route_key}' -> Lambda ${function_name}"
}

ensure_route "GET /alerts" "${ALERTS_FUNCTION_NAME}" "${ALERTS_FUNCTION_ARN}" "/alerts"
ensure_route "GET /logs" "${LOGS_FUNCTION_NAME}" "${LOGS_FUNCTION_ARN}" "/logs"

# Stage $default con auto-deploy: cualquier cambio en rutas se publica solo y
# la URL no lleva sufijo de stage.
if ! aws apigatewayv2 get-stage --api-id "${API_ID}" --stage-name '$default' >/dev/null 2>&1; then
  aws apigatewayv2 create-stage --api-id "${API_ID}" --stage-name '$default' --auto-deploy >/dev/null
fi

API_ENDPOINT=$(aws apigatewayv2 get-api --api-id "${API_ID}" --query ApiEndpoint --output text)
echo "${API_ENDPOINT}" > "${BUILD_DIR}/api-endpoint.txt"

echo "== API desplegado =="
echo "Endpoint: ${API_ENDPOINT}"
echo "Prueba:"
echo "  curl \"${API_ENDPOINT}/alerts\""
echo "  curl \"${API_ENDPOINT}/logs?top=5\""
