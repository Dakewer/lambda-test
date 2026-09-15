#!/usr/bin/env bash
# send-logs.sh — uploads every batch produced by split-log.sh to
# s3://<bucket>/input/, sleeping N seconds between each upload so the
# Lambda trigger fires once per batch, simulating logs arriving over time.
#
# Usage:
#   ./scripts/send-logs.sh <seconds_between_uploads> [batches_dir] [bucket_name]
#
# Example:
#   ./scripts/send-logs.sh 30
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <seconds_between_uploads> [batches_dir] [bucket_name]"
  echo "Example: $0 30"
  exit 1
fi

WAIT_SECONDS="$1"
BATCHES_DIR="${2:-batches}"
BUCKET_NAME="${3:-${BUCKET_NAME:-logging}}"

shopt -s nullglob
FILES=("${BATCHES_DIR}"/openssh-*.log)
shopt -u nullglob

if [ ${#FILES[@]} -eq 0 ]; then
  echo "No batch files found in ${BATCHES_DIR}/. Run ./scripts/split-log.sh first."
  exit 1
fi

echo "Uploading ${#FILES[@]} batches to s3://${BUCKET_NAME}/input/ (${WAIT_SECONDS}s apart)"

for i in "${!FILES[@]}"; do
  f="${FILES[$i]}"
  echo "[$((i + 1))/${#FILES[@]}] Uploading $(basename "$f")..."
  aws s3 cp "$f" "s3://${BUCKET_NAME}/input/$(basename "$f")"

  if [ $((i + 1)) -lt ${#FILES[@]} ]; then
    sleep "${WAIT_SECONDS}"
  fi
done

echo "Done. All batches uploaded to s3://${BUCKET_NAME}/input/"
