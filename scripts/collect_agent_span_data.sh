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

RUNS_DIR="${RUNS_DIR:-${PROJECT_ROOT}/runs}"
DATA_DIR="${DATA_DIR:-${PROJECT_ROOT}/data}"
STAMP="$(date +%Y%m%d_%H%M%S)"

RUN_DIR="${RUN_DIR:-${RUNS_DIR}/swebench_span_pilot_collect/${STAMP}}"
OUTPUT_JSONL="${OUTPUT_JSONL:-${DATA_DIR}/agent_span_data_${STAMP}.jsonl}"

PRUNER_PORT="${PRUNER_PORT:-8001}" \
PRUNER_URL="${PRUNER_URL:-http://127.0.0.1:${PRUNER_PORT}/prune}" \
RUN_DIR="${RUN_DIR}" \
LIMIT="${LIMIT:-20}" \
WORKERS="${WORKERS:-2}" \
bash "${PROJECT_ROOT}/scripts/run_swebench_span_pilot.sh"

TRAJ_DIR="${RUN_DIR}" \
OUTPUT_JSONL="${OUTPUT_JSONL}" \
SHUFFLE=1 \
bash "${PROJECT_ROOT}/scripts/build_agent_span_dataset.sh"

AGENT_JSONL="${OUTPUT_JSONL}" \
bash "${PROJECT_ROOT}/scripts/prepare_training_data.sh"

echo "Collected trajectories: ${RUN_DIR}"
echo "Agent dataset: ${OUTPUT_JSONL}"
echo "Training dataset: ${DATA_DIR}/swe-pruner-training-dataset-py.jsonl"
