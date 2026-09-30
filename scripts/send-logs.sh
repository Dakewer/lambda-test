#!/usr/bin/env bash
# send-logs.sh — uploads every batch produced by split-log.sh to
# s3://<bucket>/input/, sleeping N seconds between each upload so each
# batch triggers its own Step Functions execution, simulating logs arriving
# over time. ./scripts/start_logging.sh runs split-log.sh + this in one go.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

WAIT_SECONDS="$1"
BATCHES_DIR="${2:-batches}"
BUCKET_NAME="${3:-${BUCKET_NAME}}"

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
  echo "[$((i + 1))/${#FILES[@]}] $(date +%H:%M:%S) Uploading $(basename "$f") ($(wc -c < "$f") bytes)..."
  aws s3 cp "$f" "s3://${BUCKET_NAME}/input/$(basename "$f")" --only-show-errors

  if [ $((i + 1)) -lt ${#FILES[@]} ]; then
    sleep "${WAIT_SECONDS}"
  fi
done

echo "Done. All batches uploaded to s3://${BUCKET_NAME}/input/"
