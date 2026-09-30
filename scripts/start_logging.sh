#!/usr/bin/env bash
# start_logging.sh — simula el envío de logs: parte OpenSSH_2k.log en batches
# de ~1KB (split-log.sh) y los sube a s3://<bucket>/input/ esperando N
# segundos entre cada uno (send-logs.sh).
#
# Los batches se regeneran en cada corrida con timestamps nuevos, así que
# volver a correrlo produce items nuevos en lugar de sobrescribir los viejos.
#
# Usage:
#   ./scripts/start_logging.sh <segundos_entre_batches>
#
# Example:
#   ./scripts/start_logging.sh 30
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <segundos_entre_batches>"
  echo "Example: $0 30"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."

bash "${SCRIPT_DIR}/split-log.sh" "${ROOT_DIR}/OpenSSH_2k.log" "${ROOT_DIR}/batches" 1024
bash "${SCRIPT_DIR}/send-logs.sh" "$1" "${ROOT_DIR}/batches"
