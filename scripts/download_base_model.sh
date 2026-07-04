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

MODELS_DIR="${MODELS_DIR:-${PROJECT_ROOT}/models}"
TRAIN_ENV="${TRAIN_ENV:-${PROJECT_ROOT}/.venv-train}"
BASE_MODEL_REPO="${BASE_MODEL_REPO:-Qwen/Qwen3-Reranker-0.6B}"
BASE_MODEL_DIR="${BASE_MODEL_DIR:-${MODELS_DIR}/Qwen3-Reranker-0.6B}"
HF_ENDPOINTS="${HF_ENDPOINTS:-${HF_ENDPOINT:-https://hf-mirror.com} https://huggingface.co}"

if [[ ! -x "${TRAIN_ENV}/bin/python" ]]; then
  echo "Missing train environment: ${TRAIN_ENV}" >&2
  echo "Run bash scripts/bootstrap_span_swepruner.sh first." >&2
  exit 1
fi

mkdir -p "${BASE_MODEL_DIR}" "${MODELS_DIR}/hf_home"

if [[ -f "${BASE_MODEL_DIR}/config.json" ]]; then
  echo "Base model already exists: ${BASE_MODEL_DIR}"
  exit 0
fi

uv pip install --python "${TRAIN_ENV}/bin/python" "huggingface-hub[hf_transfer]"

export HF_HOME="${HF_HOME:-${MODELS_DIR}/hf_home}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-${HF_HOME}/hub}"
export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-${HF_HOME}/transformers}"
export HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}"
export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}"

unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY

for endpoint in ${HF_ENDPOINTS}; do
  echo "Trying ${BASE_MODEL_REPO} from ${endpoint}"
  if HF_ENDPOINT="${endpoint}" "${TRAIN_ENV}/bin/python" - <<PY
from huggingface_hub import snapshot_download

snapshot_download(
    repo_id="${BASE_MODEL_REPO}",
    local_dir="${BASE_MODEL_DIR}",
    local_dir_use_symlinks=False,
    resume_download=True,
)
PY
  then
    test -f "${BASE_MODEL_DIR}/config.json"
    echo "Base model ready: ${BASE_MODEL_DIR}"
    exit 0
  fi
done

echo "Failed to download ${BASE_MODEL_REPO}" >&2
echo "You can set HF_ENDPOINTS='https://hf-mirror.com https://huggingface.co' and retry." >&2
exit 1
