#!/usr/bin/env bash
# create-s3-bucket.sh — creates the "logging" S3 bucket (bucket names are
# globally unique in AWS, override with BUCKET_NAME or a first argument if
# "logging" is already taken) with el prefijo input/, blocking public
# access. Ya no hay prefijo output/: la Lambda escribe a DynamoDB.
#
# Usage:
#   ./scripts/create-s3-bucket.sh [bucket_name]
set -euo pipefail

BUCKET_NAME="${1:-${BUCKET_NAME:-logging-bucket-1321}}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

echo "Creating bucket '${BUCKET_NAME}' in region '${REGION}'..."

if aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
  echo "Bucket '${BUCKET_NAME}' already exists, skipping creation."
else
  if [ "${REGION}" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}"
  else
    aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}"
  fi

  aws s3api put-public-access-block --bucket "${BUCKET_NAME}" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  echo "Bucket '${BUCKET_NAME}' created."
fi

echo "Creating input/ prefix..."
aws s3api put-object --bucket "${BUCKET_NAME}" --key "input/" >/dev/null

echo "Done. Bucket ready at s3://${BUCKET_NAME}"
