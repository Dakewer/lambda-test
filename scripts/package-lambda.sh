#!/usr/bin/env bash
# package-lambda.sh — zips src/logging-system, creates the Lambda's IAM
# role if needed, creates (or updates) the "log-processing" Lambda
# function, and wires up a direct S3 -> Lambda trigger on
# s3://<bucket>/input/*.log uploads.
#
# Usage:
#   ./scripts/package-lambda.sh
#
# Config (env vars, all optional):
#   FUNCTION_NAME     (default: log-processing)
#   BUCKET_NAME       (default: logging)
#   ROLE_NAME         (default: log-processing-lambda-role)
#   FALLBACK_ROLE_NAME (default: LabRole) — used automatically when this
#                      account can't create IAM roles (e.g. AWS Academy /
#                      restricted sandbox accounts, where iam:CreateRole
#                      is denied but a pre-provisioned role like LabRole
#                      already has the needed permissions).
#   AWS_REGION        (default: aws cli configured region, or us-east-1)
set -euo pipefail

FUNCTION_NAME="${FUNCTION_NAME:-log-processing}"
BUCKET_NAME="${BUCKET_NAME:-logging}"
ROLE_NAME="${ROLE_NAME:-log-processing-lambda-role}"
FALLBACK_ROLE_NAME="${FALLBACK_ROLE_NAME:-LabRole}"
RUNTIME="python3.12"
HANDLER="lambda_function.lambda_handler"
TIMEOUT=30
MEMORY=128

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/../src/logging-system"
BUILD_DIR="${SCRIPT_DIR}/../build"
ZIP_FILE="${BUILD_DIR}/lambda.zip"

echo "== Packaging Lambda =="
# Only wipe the pkg/ subdir (the zip staging area), never the whole
# build/ dir — it also holds the .role-created-by-script marker
# teardown.sh relies on to know what it's safe to delete, and that needs
# to survive across re-runs.
rm -rf "${BUILD_DIR}/pkg"
mkdir -p "${BUILD_DIR}/pkg"
cp "${SRC_DIR}/lambda_function.py" "${BUILD_DIR}/pkg/"

if [ -s "${SRC_DIR}/requirements.txt" ] && grep -qvE '^\s*(#.*)?$' "${SRC_DIR}/requirements.txt"; then
  pip3 install -r "${SRC_DIR}/requirements.txt" -t "${BUILD_DIR}/pkg" --quiet
fi

(cd "${BUILD_DIR}/pkg" && zip -rq "${ZIP_FILE}" .)
echo "Created ${ZIP_FILE} ($(du -h "${ZIP_FILE}" | cut -f1))"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "== Ensuring IAM role =="
ROLE_CREATED_BY_SCRIPT="false"
if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "Role ${ROLE_NAME} already exists, reusing it."
else
  echo "Role ${ROLE_NAME} not found, attempting to create it..."
  if aws iam create-role --role-name "${ROLE_NAME}" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "lambda.amazonaws.com"},
        "Action": "sts:AssumeRole"
      }]
    }' >/dev/null 2>/tmp/package-lambda-create-role.err; then
    ROLE_CREATED_BY_SCRIPT="true"

    aws iam attach-role-policy --role-name "${ROLE_NAME}" \
      --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

    aws iam put-role-policy --role-name "${ROLE_NAME}" \
      --policy-name "logging-bucket-access" \
      --policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [
          {\"Effect\": \"Allow\", \"Action\": [\"s3:GetObject\"], \"Resource\": \"arn:aws:s3:::${BUCKET_NAME}/input/*\"},
          {\"Effect\": \"Allow\", \"Action\": [\"s3:PutObject\"], \"Resource\": \"arn:aws:s3:::${BUCKET_NAME}/output/*\"}
        ]
      }"

    echo "Waiting for IAM role to propagate..."
    sleep 10
  else
    echo "Could not create IAM role '${ROLE_NAME}' (likely no iam:CreateRole permission — common in restricted accounts like AWS Academy labs):"
    cat /tmp/package-lambda-create-role.err
    if aws iam get-role --role-name "${FALLBACK_ROLE_NAME}" >/dev/null 2>&1; then
      echo "Falling back to existing role '${FALLBACK_ROLE_NAME}'."
      ROLE_NAME="${FALLBACK_ROLE_NAME}"
    else
      echo "ERROR: no usable IAM role available. Set ROLE_NAME to an existing role this account is allowed to use (e.g. ROLE_NAME=LabRole) and re-run." >&2
      exit 1
    fi
  fi
fi

ROLE_ARN=$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)

mkdir -p "${BUILD_DIR}"
if [ "${ROLE_CREATED_BY_SCRIPT}" = "true" ]; then
  echo "${ROLE_NAME}" > "${BUILD_DIR}/.role-created-by-script"
else
  rm -f "${BUILD_DIR}/.role-created-by-script"
fi

echo "== Deploying Lambda function =="
if aws lambda get-function --function-name "${FUNCTION_NAME}" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "${FUNCTION_NAME}" \
    --zip-file "fileb://${ZIP_FILE}" >/dev/null
  aws lambda wait function-updated --function-name "${FUNCTION_NAME}"
  echo "Updated code for existing function ${FUNCTION_NAME}."
else
  aws lambda create-function --function-name "${FUNCTION_NAME}" \
    --runtime "${RUNTIME}" \
    --role "${ROLE_ARN}" \
    --handler "${HANDLER}" \
    --timeout "${TIMEOUT}" \
    --memory-size "${MEMORY}" \
    --zip-file "fileb://${ZIP_FILE}" >/dev/null
  aws lambda wait function-active --function-name "${FUNCTION_NAME}"
  echo "Created function ${FUNCTION_NAME}."
fi

FUNCTION_ARN=$(aws lambda get-function --function-name "${FUNCTION_NAME}" \
  --query 'Configuration.FunctionArn' --output text)

echo "== Wiring S3 -> Lambda trigger (direct notification) =="
aws lambda add-permission --function-name "${FUNCTION_NAME}" \
  --statement-id "s3-invoke-${BUCKET_NAME}" \
  --action "lambda:InvokeFunction" \
  --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::${BUCKET_NAME}" \
  --source-account "${ACCOUNT_ID}" >/dev/null 2>&1 || echo "Invoke permission already granted."

aws s3api put-bucket-notification-configuration --bucket "${BUCKET_NAME}" \
  --notification-configuration "{
    \"LambdaFunctionConfigurations\": [{
      \"LambdaFunctionArn\": \"${FUNCTION_ARN}\",
      \"Events\": [\"s3:ObjectCreated:*\"],
      \"Filter\": {\"Key\": {\"FilterRules\": [
        {\"Name\": \"prefix\", \"Value\": \"input/\"},
        {\"Name\": \"suffix\", \"Value\": \".log\"}
      ]}}
    }]
  }"

echo "Done. Function ready: ${FUNCTION_ARN}"
echo "Uploads to s3://${BUCKET_NAME}/input/*.log will now trigger ${FUNCTION_NAME}."
