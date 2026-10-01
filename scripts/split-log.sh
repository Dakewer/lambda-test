#!/usr/bin/env bash
# split-log.sh — reads a log file line by line, and every time ~1KB has been
# accumulated it flushes that chunk to its own batch file named
# openssh-<epoch de la corrida>-<índice>.log, ready to be uploaded to S3.
# The run epoch keeps names from different runs from colliding (which would
# overwrite S3 objects and DynamoDB items), and the zero-padded index keeps
# lexicographic order == upload order.
#
# Usage:
#   ./scripts/split-log.sh [source_log] [output_dir] [max_bytes]
#
# Examples:
#   ./scripts/split-log.sh                                  # downloads OpenSSH_2k.log, writes to ./batches
#   ./scripts/split-log.sh ./OpenSSH_2k.log ./batches 1024
set -euo pipefail

SOURCE_LOG="${1:-OpenSSH_2k.log}"
OUTPUT_DIR="${2:-batches}"
MAX_BYTES="${3:-1024}"
SOURCE_URL="https://raw.githubusercontent.com/logpai/loghub/master/OpenSSH/OpenSSH_2k.log"

if [ ! -f "${SOURCE_LOG}" ]; then
  echo "Source log '${SOURCE_LOG}' not found locally, downloading from loghub..."
  curl -fsSL "${SOURCE_URL}" -o "${SOURCE_LOG}"
fi

mkdir -p "${OUTPUT_DIR}"
rm -f "${OUTPUT_DIR}"/openssh-*.log

BASE_TS=$(date +%s)
BATCH_INDEX=0
CURRENT_BATCH=""
CURRENT_SIZE=0

flush_batch() {
  if [ -n "${CURRENT_BATCH}" ]; then
    local fname
    fname="${OUTPUT_DIR}/$(printf 'openssh-%s-%04d.log' "${BASE_TS}" "${BATCH_INDEX}")"
    printf '%s' "${CURRENT_BATCH}" > "${fname}"
    echo "Wrote ${fname} ($(wc -c < "${fname}") bytes)"
    BATCH_INDEX=$((BATCH_INDEX + 1))
    CURRENT_BATCH=""
    CURRENT_SIZE=0
  fi
}

# `|| [ -n "$line" ]` makes sure the last line is processed even if the
# source file doesn't end with a trailing newline.
while IFS= read -r line || [ -n "$line" ]; do
  CURRENT_BATCH="${CURRENT_BATCH}${line}"$'\n'
  CURRENT_SIZE=$((CURRENT_SIZE + ${#line} + 1))

  if [ "${CURRENT_SIZE}" -ge "${MAX_BYTES}" ]; then
    flush_batch
  fi
done < "${SOURCE_LOG}"

flush_batch

echo "Created ${BATCH_INDEX} batches in ${OUTPUT_DIR}/"
