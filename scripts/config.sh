# config.sh — configuración compartida por todos los scripts. No se ejecuta
# directo: cada script la carga con `source` después de `set -euo pipefail`.
#
# Cualquier valor se puede sobrescribir exportando la variable antes de correr
# el script, p. ej. `BUCKET_NAME=mi-bucket ./scripts/deploy.sh`.

# `tr -d '\r'` por si se corre con el aws.exe de Windows desde Git Bash.
if [ -z "${ACCOUNT_ID:-}" ]; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text | tr -d '\r') || {
    echo "ERROR: no se pudo obtener la cuenta de AWS. Revisa 'aws configure' (en AWS Academy, las credenciales del Learner Lab expiran en cada sesión)." >&2
    exit 1
  }
fi

if [ -z "${AWS_REGION:-}" ]; then
  AWS_REGION="${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null | tr -d '\r' || true)}"
  AWS_REGION="${AWS_REGION:-us-east-1}"
fi
export AWS_REGION
export AWS_DEFAULT_REGION="${AWS_REGION}"

# Los nombres de bucket S3 son únicos en *todo* AWS (no por cuenta), así que el
# default lleva el account id: cada integrante puede desplegar en su propia
# cuenta sin chocar con los demás. El resto de los recursos (tablas, Lambdas,
# state machine, roles, regla) solo tiene que ser único dentro de la
# cuenta/región, así que conservan su nombre fijo.
BUCKET_NAME="${BUCKET_NAME:-logging-bucket-${ACCOUNT_ID}}"

# DynamoDB
LOGS_TABLE_NAME="${LOGS_TABLE_NAME:-Logs}"
SECURITY_ALERTS_TABLE_NAME="${SECURITY_ALERTS_TABLE_NAME:-SecurityAlerts}"
# GSI de Logs: partition key fija (gsi_pk = "LOG", la escribe la state machine)
# + sort key last_modified (LastModified del batch en S3).
LOGS_RECENT_INDEX="${LOGS_RECENT_INDEX:-last_modified-index}"

# Step Functions + EventBridge
LAMBDA_FUNCTION_NAME="${LAMBDA_FUNCTION_NAME:-parse-batch}"
STATE_MACHINE_NAME="${STATE_MACHINE_NAME:-log-processing-state-machine}"
LAMBDA_ROLE_NAME="${LAMBDA_ROLE_NAME:-parse-batch-lambda-role}"
SFN_ROLE_NAME="${SFN_ROLE_NAME:-step-functions-log-processing-role}"
EB_RULE_NAME="${EB_RULE_NAME:-s3-log-processing-rule}"
EB_ROLE_NAME="${EB_ROLE_NAME:-eventbridge-step-functions-role}"

# Rol pre-aprovisionado que se usa cuando la cuenta no permite iam:CreateRole
# (AWS Academy).
FALLBACK_ROLE_NAME="${FALLBACK_ROLE_NAME:-LabRole}"
