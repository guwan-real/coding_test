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
TRAIN_ENV="${TRAIN_ENV:-${PROJECT_ROOT}/.venv-train}"
SOURCE="${SOURCE:-swebench}"
TEACHER_BASE_URL="${TEACHER_BASE_URL:-http://127.0.0.1:8015/v1}"
TEACHER_MODEL="${TEACHER_MODEL:-Qwen3.5-27B}"
TEACHER_WORKERS="${TEACHER_WORKERS:-8}"
MAX_SAMPLES="${MAX_SAMPLES:-0}"
TEACHER_LIMIT="${TEACHER_LIMIT:-0}"

mkdir -p "${DATA_DIR}"

if [[ ! -x "${TRAIN_ENV}/bin/python" ]]; then
  echo "Missing train environment: ${TRAIN_ENV}" >&2
  echo "Run bash ${PROJECT_ROOT}/scripts/bootstrap_span_swepruner.sh first." >&2
  exit 1
fi

if [[ "${SOURCE}" == "swebench" ]]; then
  INPUT_JSONL="${INPUT_JSONL:-${DATA_DIR}/swebench_train.jsonl}"
  REPO_ROOT="${REPO_ROOT:-${DATA_DIR}/swebench_repos}"
  if [[ ! -f "${INPUT_JSONL}" ]]; then
    echo "Missing SWE-bench train metadata JSONL: ${INPUT_JSONL}" >&2
    echo "Set INPUT_JSONL=/absolute/path/to/swebench_train.jsonl." >&2
    exit 1
  fi
  if [[ ! -d "${REPO_ROOT}" ]]; then
    echo "Missing SWE-bench repo checkout root: ${REPO_ROOT}" >&2
    echo "Set REPO_ROOT=/absolute/path/to/repo/checkouts." >&2
    exit 1
  fi
  CANDIDATES_JSONL="${CANDIDATES_JSONL:-${DATA_DIR}/repair_candidates.swebench_train.jsonl}"
  "${TRAIN_ENV}/bin/python" "${PROJECT_ROOT}/scripts/build_repair_candidates.py" \
    --source swebench \
    --input "${INPUT_JSONL}" \
    --repo-root "${REPO_ROOT}" \
    --output "${CANDIDATES_JSONL}" \
    --lang python \
    ${CHECKOUT_BASE_COMMIT:+--checkout-base-commit} \
    ${MAX_SAMPLES:+--max-samples "${MAX_SAMPLES}"}
elif [[ "${SOURCE}" == "official_swepruner" ]]; then
  INPUT_JSONL="${INPUT_JSONL:-${DATA_DIR}/swe-pruner-training-dataset-py.jsonl}"
  if [[ ! -f "${INPUT_JSONL}" ]]; then
    echo "Missing official SWE-Pruner JSONL: ${INPUT_JSONL}" >&2
    echo "Run bash ${PROJECT_ROOT}/scripts/download_official_training_data.sh or set INPUT_JSONL." >&2
    exit 1
  fi
  CANDIDATES_JSONL="${CANDIDATES_JSONL:-${DATA_DIR}/repair_candidates.official61k.jsonl}"
  "${TRAIN_ENV}/bin/python" "${PROJECT_ROOT}/scripts/build_repair_candidates.py" \
    --source official_swepruner \
    --input "${INPUT_JSONL}" \
    --output "${CANDIDATES_JSONL}" \
    --lang python \
    ${MAX_SAMPLES:+--max-samples "${MAX_SAMPLES}"}
else
  echo "Unknown SOURCE=${SOURCE}; expected swebench or official_swepruner." >&2
  exit 1
fi

TEACHER_JSONL="${TEACHER_JSONL:-${DATA_DIR}/repair_teacher_labels.${SOURCE}.qwen35.jsonl}"
VALID_JSONL="${VALID_JSONL:-${DATA_DIR}/repair_teacher_labels.${SOURCE}.qwen35.valid.jsonl}"
REJECT_JSONL="${REJECT_JSONL:-${DATA_DIR}/repair_teacher_labels.${SOURCE}.qwen35.reject.jsonl}"
TRAIN_JSONL="${TRAIN_JSONL:-${DATA_DIR}/swepruner_repair_qwen35_train.jsonl}"
INSPECT_MD="${INSPECT_MD:-${DATA_DIR}/inspect_repair_labels.${SOURCE}.md}"

"${TRAIN_ENV}/bin/python" "${PROJECT_ROOT}/scripts/teacher_label_repair_context.py" \
  --input "${CANDIDATES_JSONL}" \
  --output "${TEACHER_JSONL}" \
  --base-url "${TEACHER_BASE_URL}" \
  --model "${TEACHER_MODEL}" \
  --temperature "${TEACHER_TEMPERATURE:-0}" \
  --max-tokens "${TEACHER_MAX_TOKENS:-2048}" \
  --num-workers "${TEACHER_WORKERS}" \
  ${TEACHER_LIMIT:+--limit "${TEACHER_LIMIT}"}

"${TRAIN_ENV}/bin/python" "${PROJECT_ROOT}/scripts/validate_teacher_labels.py" \
  --input "${TEACHER_JSONL}" \
  --output "${VALID_JSONL}" \
  --reject-output "${REJECT_JSONL}" \
  --max-support-lines-per-sample "${MAX_SUPPORT_LINES_PER_SAMPLE:-200}" \
  --max-helper-regions "${MAX_HELPER_REGIONS:-3}"

"${TRAIN_ENV}/bin/python" "${PROJECT_ROOT}/scripts/export_swepruner_training_jsonl.py" \
  --input "${VALID_JSONL}" \
  --output "${TRAIN_JSONL}" \
  --score-default "${SCORE_DEFAULT:-1.0}"

"${TRAIN_ENV}/bin/python" "${PROJECT_ROOT}/scripts/inspect_repair_labels.py" \
  --input "${TRAIN_JSONL}" \
  --output "${INSPECT_MD}" \
  --num-samples "${INSPECT_SAMPLES:-50}"

echo "Repair-aware training data ready: ${TRAIN_JSONL}"
echo "Inspection report: ${INSPECT_MD}"
