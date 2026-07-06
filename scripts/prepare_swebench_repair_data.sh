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
SWEBENCH_DATASET="${SWEBENCH_DATASET:-SWE-bench/SWE-bench}"
SWEBENCH_SPLIT="${SWEBENCH_SPLIT:-train}"
SWEBENCH_JSONL="${SWEBENCH_JSONL:-${DATA_DIR}/swebench_train.jsonl}"
SWEBENCH_REPO_ROOT="${SWEBENCH_REPO_ROOT:-${DATA_DIR}/swebench_repos}"
SWEBENCH_HF_ENDPOINT="${SWEBENCH_HF_ENDPOINT:-official}"
SWEBENCH_DISABLE_PROXY="${SWEBENCH_DISABLE_PROXY:-0}"
SWEBENCH_GIT_DIRECT="${SWEBENCH_GIT_DIRECT:-0}"
MAX_SWEBENCH_SAMPLES="${MAX_SWEBENCH_SAMPLES:-0}"
MAX_REPOS="${MAX_REPOS:-0}"
SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-0}"
SKIP_REPO_CLONE="${SKIP_REPO_CLONE:-0}"
RUN_REPAIR_PIPELINE="${RUN_REPAIR_PIPELINE:-1}"

mkdir -p "${DATA_DIR}" "${SWEBENCH_REPO_ROOT}"
export PYTHONUNBUFFERED=1

if [[ ! -x "${TRAIN_ENV}/bin/python" ]]; then
  echo "Missing train environment: ${TRAIN_ENV}" >&2
  echo "Run bash ${PROJECT_ROOT}/scripts/bootstrap_span_swepruner.sh first." >&2
  exit 1
fi

if ! "${TRAIN_ENV}/bin/python" - <<'PY' >/dev/null 2>&1
import datasets
PY
then
  uv pip install --python "${TRAIN_ENV}/bin/python" datasets
fi

if [[ "${SKIP_DOWNLOAD}" != "1" ]]; then
  echo "[swebench-repair] stage 1/3: downloading SWE-bench metadata"
  HF_ENV=(env)
  case "${SWEBENCH_HF_ENDPOINT}" in
    official|direct|"")
      HF_ENV+=(-u HF_ENDPOINT -u HF_HUB_ENDPOINT)
      ;;
    mirror|hf-mirror)
      HF_ENV+=(HF_ENDPOINT=https://hf-mirror.com)
      ;;
    http://*|https://*)
      HF_ENV+=(HF_ENDPOINT="${SWEBENCH_HF_ENDPOINT}")
      ;;
    *)
      echo "Unknown SWEBENCH_HF_ENDPOINT=${SWEBENCH_HF_ENDPOINT}; use official, mirror, or a URL." >&2
      exit 1
      ;;
  esac
  if [[ "${SWEBENCH_DISABLE_PROXY}" == "1" ]]; then
    HF_ENV+=(-u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY)
  fi
  "${HF_ENV[@]}" "${TRAIN_ENV}/bin/python" -u "${PROJECT_ROOT}/scripts/download_swebench_train.py" \
    --dataset "${SWEBENCH_DATASET}" \
    --split "${SWEBENCH_SPLIT}" \
    --output "${SWEBENCH_JSONL}" \
    ${MAX_SWEBENCH_SAMPLES:+--max-samples "${MAX_SWEBENCH_SAMPLES}"}
else
  echo "[swebench-repair] stage 1/3: using existing SWE-bench metadata: ${SWEBENCH_JSONL}"
fi

if [[ "${SKIP_REPO_CLONE}" != "1" ]]; then
  echo "[swebench-repair] stage 2/3: cloning/fetching SWE-bench repos"
  GIT_DIRECT_ARGS=(--no-direct)
  if [[ "${SWEBENCH_GIT_DIRECT}" == "1" ]]; then
    GIT_DIRECT_ARGS=(--direct)
  fi
  "${TRAIN_ENV}/bin/python" -u "${PROJECT_ROOT}/scripts/clone_swebench_repos.py" \
    --input "${SWEBENCH_JSONL}" \
    --repo-root "${SWEBENCH_REPO_ROOT}" \
    "${GIT_DIRECT_ARGS[@]}" \
    --continue-on-error \
    ${MAX_REPOS:+--max-repos "${MAX_REPOS}"}
else
  echo "[swebench-repair] stage 2/3: using existing repo root: ${SWEBENCH_REPO_ROOT}"
fi

if [[ "${RUN_REPAIR_PIPELINE}" == "1" ]]; then
  echo "[swebench-repair] stage 3/3: building repair-aware SWE-bench training data"
  SOURCE=swebench \
  INPUT_JSONL="${SWEBENCH_JSONL}" \
  REPO_ROOT="${SWEBENCH_REPO_ROOT}" \
  CHECKOUT_BASE_COMMIT=1 \
  MAX_SAMPLES="${MAX_REPAIR_SAMPLES:-${MAX_SWEBENCH_SAMPLES}}" \
  PROGRESS_EVERY="${PROGRESS_EVERY:-20}" \
  TEACHER_PROGRESS_EVERY="${TEACHER_PROGRESS_EVERY:-5}" \
  TEACHER_BASE_URL="${TEACHER_BASE_URL:-http://127.0.0.1:8015/v1}" \
  TEACHER_MODEL="${TEACHER_MODEL:-Qwen3.5-27B}" \
  TEACHER_WORKERS="${TEACHER_WORKERS:-4}" \
  bash "${PROJECT_ROOT}/scripts/run_repair_aware_pipeline.sh"
else
  echo "[swebench-repair] stage 3/3: skipped repair pipeline"
fi
