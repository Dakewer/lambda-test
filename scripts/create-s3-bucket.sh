#!/usr/bin/env bash
# create-s3-bucket.sh — crea el bucket de logs (default
# logging-bucket-<account_id>, ver config.sh) con el prefijo input/,
# bloqueando el acceso público.
#
# Usage:
#   ./scripts/create-s3-bucket.sh [bucket_name]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

BUCKET_NAME="${1:-${BUCKET_NAME}}"

echo "Creating bucket '${BUCKET_NAME}' in region '${AWS_REGION}'..."

if aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
  echo "Bucket '${BUCKET_NAME}' already exists, skipping creation."
else
  if [ "${AWS_REGION}" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${AWS_REGION}" >/dev/null
  else
    aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${AWS_REGION}" \
      --create-bucket-configuration LocationConstraint="${AWS_REGION}" >/dev/null
  fi

  aws s3api put-public-access-block --bucket "${BUCKET_NAME}" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  echo "Bucket '${BUCKET_NAME}' created."
fi

echo "Creating input/ prefix..."
aws s3api put-object --bucket "${BUCKET_NAME}" --key "input/" >/dev/null

echo "Done. Bucket ready at s3://${BUCKET_NAME}"
