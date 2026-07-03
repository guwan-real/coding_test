#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
if [[ -f "${PROJECT_ROOT}/.env.server" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${PROJECT_ROOT}/.env.server"
  set +a
fi

DATA_DIR="${DATA_DIR:-${PROJECT_ROOT}/data}"
TRAJ_DIR="${TRAJ_DIR:-${PROJECT_ROOT}/runs/swebench_span_pilot}"
OUTPUT_JSONL="${OUTPUT_JSONL:-${DATA_DIR}/agent_span_data.jsonl}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

ARGS=(
  "${PROJECT_ROOT}/scripts/build_agent_span_dataset.py"
  --traj-dir "${TRAJ_DIR}" \
  --output-jsonl "${OUTPUT_JSONL}" \
  --min-chars "${MIN_CHARS:-500}" \
  --min-kept "${MIN_KEEP_LINES:-1}" \
  --max-keep-ratio "${MAX_KEEP_RATIO:-0.95}"
)

if [[ -n "${MAX_EXAMPLES:-}" ]]; then
  ARGS+=(--max-examples "${MAX_EXAMPLES}")
fi
if [[ -n "${SHUFFLE:-}" ]]; then
  ARGS+=(--shuffle)
fi

"${PYTHON_BIN}" "${ARGS[@]}"

echo "Agent-native span data: ${OUTPUT_JSONL}"
