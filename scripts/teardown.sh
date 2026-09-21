#!/usr/bin/env bash
# teardown.sh — removes everything the infrastructure scripts created:
# the S3 notification, the Lambda function, the IAM role (if this project
# created it), the DynamoDB table and the S3 bucket itself (including its
# contents).
#
# Usage:
#   ./scripts/teardown.sh
set -uo pipefail

FUNCTION_NAME="${FUNCTION_NAME:-log-processing}"
BUCKET_NAME="${BUCKET_NAME:-logging-bucket-1321}"
TABLE_NAME="${TABLE_NAME:-log-events}"
ROLE_NAME="${ROLE_NAME:-log-processing-lambda-role}"

BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../build"
ROLE_MARKER="${BUILD_DIR}/.role-created-by-script"

echo "== Removing S3 bucket notification =="
aws s3api put-bucket-notification-configuration --bucket "${BUCKET_NAME}" \
  --notification-configuration '{}' 2>/dev/null || true

echo "== Deleting Lambda function =="
aws lambda delete-function --function-name "${FUNCTION_NAME}" 2>/dev/null \
  && echo "Deleted ${FUNCTION_NAME}." || echo "Function not found, skipping."

echo "== Deleting IAM role =="
# Only touch the role if package-lambda.sh actually created it (tracked via
# the marker it leaves in build/). Never delete a pre-existing/shared role
# (e.g. LabRole in AWS Academy accounts) that this project didn't create.
if [ -f "${ROLE_MARKER}" ] && [ "$(cat "${ROLE_MARKER}")" = "${ROLE_NAME}" ]; then
  aws iam delete-role-policy --role-name "${ROLE_NAME}" \
    --policy-name "logging-bucket-access" 2>/dev/null || true
  aws iam detach-role-policy --role-name "${ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" 2>/dev/null || true
  aws iam delete-role --role-name "${ROLE_NAME}" 2>/dev/null \
    && echo "Deleted role ${ROLE_NAME}." || echo "Role not found, skipping."
else
  echo "Role ${ROLE_NAME} was not created by this project (or marker missing), leaving it untouched."
fi

echo "== Deleting DynamoDB table =="
aws dynamodb delete-table --table-name "${TABLE_NAME}" >/dev/null 2>&1 \
  && echo "Deleted table ${TABLE_NAME}." || echo "Table not found, skipping."

echo "== Emptying and deleting S3 bucket =="
aws s3 rm "s3://${BUCKET_NAME}" --recursive 2>/dev/null || true
aws s3api delete-bucket --bucket "${BUCKET_NAME}" 2>/dev/null \
  && echo "Deleted bucket ${BUCKET_NAME}." || echo "Bucket not found, skipping."

echo "== Cleaning local build artifacts =="
rm -rf "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../build"

echo "Teardown complete."
