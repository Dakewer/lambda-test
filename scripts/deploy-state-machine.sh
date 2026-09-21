#!/usr/bin/env bash
# deploy-state-machine.sh — empaqueta y despliega la Lambda parse_batch,
# crea los roles IAM correspondientes (o usa LabRole en AWS Academy),
# despliega/actualiza la State Machine en Step Functions y configura la regla
# de EventBridge para iniciar la ejecución al subir batches a s3://<bucket>/input/*.log.
#
# Decisiones de diseño de arquitectura:
# 1. Desacoplamiento de responsabilidades (Separation of Concerns):
#    En lugar de una Lambda monolítica que descargue, parsee, clasifique y escriba en DynamoDB,
#    la nueva Lambda 'parse_batch' se limita exclusivamente a descargar y parsear el batch en
#    líneas estructuradas. Step Functions asume la orquestación, el flujo condicional (Choice state)
#    y la persistencia en DynamoDB vía integración directa SDK (arn:aws:states:::dynamodb:putItem).
# 2. Desencadenador reactivo mediante S3 -> EventBridge -> Step Functions:
#    El uso de EventBridge desvincula el ciclo de vida de S3 del motor de Step Functions, permitiendo
#    filtrado declarativo por prefijo ('input/') y transformación de payload (InputTransformer)
#    sin intermediarios ni código glue. Evita colisiones de notificaciones directas en S3.
# 3. Resiliencia y manejo de throttling (Backoff & Retry):
#    Cada tarea de DynamoDB en la máquina de estados incorpora políticas de reintento exponencial
#    para ProvisionedThroughputExceededException y DynamoDB.AmazonDynamoDBException, protegiendo el
#    sistema ante ráfagas de escritura sin pérdida de datos.
# 4. Compatibilidad con entornos restringidos (AWS Academy):
#    El script detecta si la cuenta permite la creación de roles IAM (iam:CreateRole). Si falla
#    por restricciones de permisos (común en sandboxes de AWS Academy), conmuta automáticamente
#    al rol pre-aprovisionado 'LabRole'.
#
# Usage:
#   ./scripts/deploy-state-machine.sh
set -euo pipefail

LAMBDA_FUNCTION_NAME="${LAMBDA_FUNCTION_NAME:-parse-batch}"
STATE_MACHINE_NAME="${STATE_MACHINE_NAME:-log-processing-state-machine}"
BUCKET_NAME="${BUCKET_NAME:-logging-bucket-1321}"
LOGS_TABLE_NAME="${LOGS_TABLE_NAME:-Logs}"
SECURITY_ALERTS_TABLE_NAME="${SECURITY_ALERTS_TABLE_NAME:-SecurityAlerts}"

LAMBDA_ROLE_NAME="${LAMBDA_ROLE_NAME:-parse-batch-lambda-role}"
SFN_ROLE_NAME="${SFN_ROLE_NAME:-step-functions-log-processing-role}"
EB_RULE_NAME="${EB_RULE_NAME:-s3-log-processing-rule}"
EB_ROLE_NAME="${EB_ROLE_NAME:-eventbridge-step-functions-role}"
FALLBACK_ROLE_NAME="${FALLBACK_ROLE_NAME:-LabRole}"

RUNTIME="python3.12"
HANDLER="lambda_function.lambda_handler"
TIMEOUT=30
MEMORY=128

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
SRC_DIR="${ROOT_DIR}/src/parse-batch"
BUILD_DIR="${ROOT_DIR}/build"
ASL_FILE="${ROOT_DIR}/src/step-functions/state-machine.asl.json"
ZIP_FILE="${BUILD_DIR}/parse-batch.zip"

mkdir -p "${BUILD_DIR}"

echo "== Verificando identidad de AWS =="
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}"
echo "Cuenta: ${ACCOUNT_ID}, Región: ${AWS_REGION}"

# -----------------------------------------------------------------------------
# 1. Empaquetar la Lambda parse_batch
# -----------------------------------------------------------------------------
echo "== Empaquetando Lambda parse_batch =="
rm -rf "${BUILD_DIR}/parse-batch-pkg"
mkdir -p "${BUILD_DIR}/parse-batch-pkg"
cp "${SRC_DIR}/lambda_function.py" "${BUILD_DIR}/parse-batch-pkg/"

if [ -s "${SRC_DIR}/requirements.txt" ] && grep -qvE '^\s*(#.*)?$' "${SRC_DIR}/requirements.txt"; then
  pip3 install -r "${SRC_DIR}/requirements.txt" -t "${BUILD_DIR}/parse-batch-pkg" --quiet
fi

(cd "${BUILD_DIR}/parse-batch-pkg" && zip -rq "${ZIP_FILE}" .)
echo "Lambda empaquetada: ${ZIP_FILE} ($(du -h "${ZIP_FILE}" | cut -f1))"

# -----------------------------------------------------------------------------
# 2. Rol IAM para la Lambda parse_batch
# -----------------------------------------------------------------------------
echo "== Verificando rol IAM de Lambda (${LAMBDA_ROLE_NAME}) =="
LAMBDA_ROLE_CREATED="false"
if aws iam get-role --role-name "${LAMBDA_ROLE_NAME}" >/dev/null 2>&1; then
  echo "Rol ${LAMBDA_ROLE_NAME} ya existe, reutilizando."
else
  echo "Intentando crear rol ${LAMBDA_ROLE_NAME}..."
  if aws iam create-role --role-name "${LAMBDA_ROLE_NAME}" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "lambda.amazonaws.com"},
        "Action": "sts:AssumeRole"
      }]
    }' >/dev/null 2>/tmp/create-lambda-role.err; then
    LAMBDA_ROLE_CREATED="true"
    aws iam attach-role-policy --role-name "${LAMBDA_ROLE_NAME}" \
      --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

    aws iam put-role-policy --role-name "${LAMBDA_ROLE_NAME}" \
      --policy-name "parse-batch-s3-access" \
      --policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [
          {\"Effect\": \"Allow\", \"Action\": [\"s3:GetObject\"], \"Resource\": \"arn:aws:s3:::${BUCKET_NAME}/input/*\"}
        ]
      }"
    echo "Esperando propagación del rol IAM..."
    sleep 10
  else
    echo "No se pudo crear el rol '${LAMBDA_ROLE_NAME}' (posible restricción de AWS Academy)."
    cat /tmp/create-lambda-role.err
    if aws iam get-role --role-name "${FALLBACK_ROLE_NAME}" >/dev/null 2>&1; then
      echo "Usando rol fallback '${FALLBACK_ROLE_NAME}'."
      LAMBDA_ROLE_NAME="${FALLBACK_ROLE_NAME}"
    else
      echo "ERROR: No hay rol IAM utilizable para Lambda." >&2
      exit 1
    fi
  fi
fi

if [ "${LAMBDA_ROLE_CREATED}" = "true" ]; then
  echo "${LAMBDA_ROLE_NAME}" > "${BUILD_DIR}/.parse-batch-role-created-by-script"
fi
LAMBDA_ROLE_ARN=$(aws iam get-role --role-name "${LAMBDA_ROLE_NAME}" --query 'Role.Arn' --output text)

# -----------------------------------------------------------------------------
# 3. Desplegar / actualizar Lambda parse_batch
# -----------------------------------------------------------------------------
echo "== Desplegando Lambda ${LAMBDA_FUNCTION_NAME} =="
if aws lambda get-function --function-name "${LAMBDA_FUNCTION_NAME}" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "${LAMBDA_FUNCTION_NAME}" \
    --zip-file "fileb://${ZIP_FILE}" >/dev/null
  aws lambda wait function-updated --function-name "${LAMBDA_FUNCTION_NAME}"
  echo "Función Lambda ${LAMBDA_FUNCTION_NAME} actualizada."
else
  aws lambda create-function --function-name "${LAMBDA_FUNCTION_NAME}" \
    --runtime "${RUNTIME}" \
    --role "${LAMBDA_ROLE_ARN}" \
    --handler "${HANDLER}" \
    --timeout "${TIMEOUT}" \
    --memory-size "${MEMORY}" \
    --zip-file "fileb://${ZIP_FILE}" >/dev/null
  aws lambda wait function-active --function-name "${LAMBDA_FUNCTION_NAME}"
  echo "Función Lambda ${LAMBDA_FUNCTION_NAME} creada."
fi

PARSE_BATCH_LAMBDA_ARN=$(aws lambda get-function --function-name "${LAMBDA_FUNCTION_NAME}" \
  --query 'Configuration.FunctionArn' --output text)

# -----------------------------------------------------------------------------
# 4. Rol IAM para Step Functions
# -----------------------------------------------------------------------------
echo "== Verificando rol IAM de Step Functions (${SFN_ROLE_NAME}) =="
SFN_ROLE_CREATED="false"
if aws iam get-role --role-name "${SFN_ROLE_NAME}" >/dev/null 2>&1; then
  echo "Rol ${SFN_ROLE_NAME} ya existe, reutilizando."
else
  echo "Intentando crear rol ${SFN_ROLE_NAME}..."
  if aws iam create-role --role-name "${SFN_ROLE_NAME}" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "states.amazonaws.com"},
        "Action": "sts:AssumeRole"
      }]
    }' >/dev/null 2>/tmp/create-sfn-role.err; then
    SFN_ROLE_CREATED="true"

    aws iam put-role-policy --role-name "${SFN_ROLE_NAME}" \
      --policy-name "step-functions-access" \
      --policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [
          {
            \"Effect\": \"Allow\",
            \"Action\": [\"lambda:InvokeFunction\"],
            \"Resource\": [\"${PARSE_BATCH_LAMBDA_ARN}\", \"${PARSE_BATCH_LAMBDA_ARN}:*\"]
          },
          {
            \"Effect\": \"Allow\",
            \"Action\": [\"dynamodb:PutItem\"],
            \"Resource\": [
              \"arn:aws:dynamodb:*:*:table/${LOGS_TABLE_NAME}\",
              \"arn:aws:dynamodb:*:*:table/${SECURITY_ALERTS_TABLE_NAME}\"
            ]
          }
        ]
      }"
    echo "Esperando propagación del rol IAM de Step Functions..."
    sleep 10
  else
    echo "No se pudo crear el rol '${SFN_ROLE_NAME}' (posible restricción de AWS Academy)."
    cat /tmp/create-sfn-role.err
    if aws iam get-role --role-name "${FALLBACK_ROLE_NAME}" >/dev/null 2>&1; then
      echo "Usando rol fallback '${FALLBACK_ROLE_NAME}' para Step Functions."
      SFN_ROLE_NAME="${FALLBACK_ROLE_NAME}"
    else
      echo "ERROR: No hay rol IAM utilizable para Step Functions." >&2
      exit 1
    fi
  fi
fi

if [ "${SFN_ROLE_CREATED}" = "true" ]; then
  echo "${SFN_ROLE_NAME}" > "${BUILD_DIR}/.sfn-role-created-by-script"
fi
SFN_ROLE_ARN=$(aws iam get-role --role-name "${SFN_ROLE_NAME}" --query 'Role.Arn' --output text)

# -----------------------------------------------------------------------------
# 5. Desplegar / actualizar State Machine en Step Functions
# -----------------------------------------------------------------------------
echo "== Preparando definición de la State Machine =="
DEFINITION=$(sed \
  -e "s|\${PARSE_BATCH_LAMBDA_ARN}|${PARSE_BATCH_LAMBDA_ARN}|g" \
  -e "s|\${LOGS_TABLE_NAME}|${LOGS_TABLE_NAME}|g" \
  -e "s|\${SECURITY_ALERTS_TABLE_NAME}|${SECURITY_ALERTS_TABLE_NAME}|g" \
  "${ASL_FILE}")

echo "== Desplegando Step Functions State Machine (${STATE_MACHINE_NAME}) =="
STATE_MACHINE_ARN=$(aws stepfunctions list-state-machines \
  --query "stateMachines[?name=='${STATE_MACHINE_NAME}'].stateMachineArn" \
  --output text 2>/dev/null || true)

if [ -n "${STATE_MACHINE_ARN}" ] && [ "${STATE_MACHINE_ARN}" != "None" ]; then
  echo "Actualizando State Machine existente ${STATE_MACHINE_NAME}..."
  aws stepfunctions update-state-machine \
    --state-machine-arn "${STATE_MACHINE_ARN}" \
    --definition "${DEFINITION}" \
    --role-arn "${SFN_ROLE_ARN}" >/dev/null
  echo "State Machine actualizada."
else
  echo "Creando State Machine ${STATE_MACHINE_NAME}..."
  STATE_MACHINE_ARN=$(aws stepfunctions create-state-machine \
    --name "${STATE_MACHINE_NAME}" \
    --definition "${DEFINITION}" \
    --role-arn "${SFN_ROLE_ARN}" \
    --type "STANDARD" \
    --query "stateMachineArn" \
    --output text)
  echo "State Machine creada: ${STATE_MACHINE_ARN}"
fi

# -----------------------------------------------------------------------------
# 6. Habilitar notificaciones EventBridge en S3
# -----------------------------------------------------------------------------
echo "== Habilitando EventBridge notifications en bucket ${BUCKET_NAME} =="
aws s3api put-bucket-notification-configuration --bucket "${BUCKET_NAME}" \
  --notification-configuration '{"EventBridgeConfiguration": {}}'
echo "Notificaciones EventBridge activadas en s3://${BUCKET_NAME}."

# -----------------------------------------------------------------------------
# 7. Rol IAM para que EventBridge invoque Step Functions
# -----------------------------------------------------------------------------
echo "== Verificando rol IAM para EventBridge (${EB_ROLE_NAME}) =="
EB_ROLE_CREATED="false"
if aws iam get-role --role-name "${EB_ROLE_NAME}" >/dev/null 2>&1; then
  echo "Rol ${EB_ROLE_NAME} ya existe, reutilizando."
else
  echo "Intentando crear rol ${EB_ROLE_NAME}..."
  if aws iam create-role --role-name "${EB_ROLE_NAME}" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "events.amazonaws.com"},
        "Action": "sts:AssumeRole"
      }]
    }' >/dev/null 2>/tmp/create-eb-role.err; then
    EB_ROLE_CREATED="true"

    aws iam put-role-policy --role-name "${EB_ROLE_NAME}" \
      --policy-name "eventbridge-invoke-sfn" \
      --policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [{
          \"Effect\": \"Allow\",
          \"Action\": [\"states:StartExecution\"],
          \"Resource\": \"${STATE_MACHINE_ARN}\"
        }]
      }"
    echo "Esperando propagación del rol IAM de EventBridge..."
    sleep 10
  else
    echo "No se pudo crear el rol '${EB_ROLE_NAME}' (posible restricción de AWS Academy)."
    cat /tmp/create-eb-role.err
    if aws iam get-role --role-name "${FALLBACK_ROLE_NAME}" >/dev/null 2>&1; then
      echo "Usando rol fallback '${FALLBACK_ROLE_NAME}' para EventBridge."
      EB_ROLE_NAME="${FALLBACK_ROLE_NAME}"
    else
      echo "ERROR: No hay rol IAM utilizable para EventBridge." >&2
      exit 1
    fi
  fi
fi

if [ "${EB_ROLE_CREATED}" = "true" ]; then
  echo "${EB_ROLE_NAME}" > "${BUILD_DIR}/.eb-role-created-by-script"
fi
EB_ROLE_ARN=$(aws iam get-role --role-name "${EB_ROLE_NAME}" --query 'Role.Arn' --output text)

# -----------------------------------------------------------------------------
# 8. Crear / actualizar regla de EventBridge y Target
# -----------------------------------------------------------------------------
echo "== Configurando regla EventBridge ${EB_RULE_NAME} =="
aws events put-rule \
  --name "${EB_RULE_NAME}" \
  --description "Dispara Step Functions cuando se crea un objeto en input/*.log en ${BUCKET_NAME}" \
  --event-pattern "{
    \"source\": [\"aws.s3\"],
    \"detail-type\": [\"Object Created\"],
    \"detail\": {
      \"bucket\": {
        \"name\": [\"${BUCKET_NAME}\"]
      },
      \"object\": {
        \"key\": [{\"prefix\": \"input/\"}]
      }
    }
  }" \
  --state ENABLED >/dev/null

echo "== Conectando target EventBridge -> Step Functions =="
TARGETS_JSON=$(cat <<EOF
[{
  "Id": "StepFunctionsTarget",
  "Arn": "${STATE_MACHINE_ARN}",
  "RoleArn": "${EB_ROLE_ARN}",
  "InputTransformer": {
    "InputPathsMap": {
      "bucket": "$.detail.bucket.name",
      "key": "$.detail.object.key"
    },
    "InputTemplate": "{\"bucket\": <bucket>, \"key\": <key>}"
  }
}]
EOF
)

aws events put-targets \
  --rule "${EB_RULE_NAME}" \
  --targets "${TARGETS_JSON}" >/dev/null

echo "== Despliegue completado con éxito =="
echo "State Machine ARN: ${STATE_MACHINE_ARN}"
echo "Lambda ARN:        ${PARSE_BATCH_LAMBDA_ARN}"
echo "EventBridge Rule:  ${EB_RULE_NAME}"
echo "Tablas DynamoDB:   ${LOGS_TABLE_NAME} (normales), ${SECURITY_ALERTS_TABLE_NAME} (sospechosos)"
echo "Cualquier archivo subido a s3://${BUCKET_NAME}/input/*.log disparará automáticamente el flujo."
