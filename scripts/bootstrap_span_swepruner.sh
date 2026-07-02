#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
PROJECT_NAME="${PROJECT_NAME:-$(basename "${PROJECT_ROOT}")}"

DATA_DIR="${DATA_DIR:-${PROJECT_ROOT}/data}"
RUNS_DIR="${RUNS_DIR:-${PROJECT_ROOT}/runs}"
MODELS_DIR="${MODELS_DIR:-${PROJECT_ROOT}/models}"
LOG_DIR="${LOG_DIR:-${PROJECT_ROOT}/logs}"

HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
HF_HOME="${HF_HOME:-${MODELS_DIR}/hf_home}"
HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-${HF_HOME}/hub}"
TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-${HF_HOME}/transformers}"

PRUNER_ENV="${PRUNER_ENV:-${PROJECT_ROOT}/.venv-pruner}"
TRAIN_ENV="${TRAIN_ENV:-${PROJECT_ROOT}/.venv-train}"
MINI_ENV="${MINI_ENV:-${PROJECT_ROOT}/.venv-mini}"

INSTALL_PRUNER_ENV="${INSTALL_PRUNER_ENV:-1}"
INSTALL_TRAIN_ENV="${INSTALL_TRAIN_ENV:-1}"
INSTALL_MINI_ENV="${INSTALL_MINI_ENV:-1}"
INSTALL_FLASH_ATTN="${INSTALL_FLASH_ATTN:-1}"
DOWNLOAD_MODELS="${DOWNLOAD_MODELS:-1}"
DOWNLOAD_BASE_MODEL="${DOWNLOAD_BASE_MODEL:-0}"

PRUNER_MODEL_REPO="${PRUNER_MODEL_REPO:-ayanami-kitasan/code-pruner}"
PRUNER_MODEL_DIR="${PRUNER_MODEL_DIR:-${MODELS_DIR}/code-pruner}"
BASE_MODEL_REPO="${BASE_MODEL_REPO:-Qwen/Qwen3-Reranker-0.6B}"
BASE_MODEL_DIR="${BASE_MODEL_DIR:-${MODELS_DIR}/Qwen3-Reranker-0.6B}"

export HF_ENDPOINT HF_HOME HUGGINGFACE_HUB_CACHE TRANSFORMERS_CACHE

install_uv() {
  if command -v uv >/dev/null 2>&1; then
    return
  fi
  python3 -m pip install --user -U uv
  export PATH="${HOME}/.local/bin:${PATH}"
}

has_real_safetensors() {
  local file="$1"
  [[ -s "${file}" ]] || return 1
  local bytes
  bytes="$(wc -c < "${file}")"
  [[ "${bytes}" -gt 100000000 ]]
}

mkdir -p "${DATA_DIR}" "${RUNS_DIR}" "${MODELS_DIR}" "${LOG_DIR}" "${HF_HOME}" "${HUGGINGFACE_HUB_CACHE}" "${TRANSFORMERS_CACHE}"
install_uv

if [[ "${INSTALL_PRUNER_ENV}" == "1" ]]; then
  uv venv --python 3.12 "${PRUNER_ENV}"
  uv pip install --python "${PRUNER_ENV}/bin/python" torch torchvision --index-url https://download.pytorch.org/whl/cu126
  uv pip install --python "${PRUNER_ENV}/bin/python" -e "${PROJECT_ROOT}/swe-pruner"
  if [[ "${INSTALL_FLASH_ATTN}" == "1" ]]; then
    uv pip install --python "${PRUNER_ENV}/bin/python" flash-attn --no-build-isolation || true
  fi
fi

if [[ "${INSTALL_TRAIN_ENV}" == "1" ]]; then
  uv venv --python 3.12 "${TRAIN_ENV}"
  uv pip install --python "${TRAIN_ENV}/bin/python" torch torchvision --index-url https://download.pytorch.org/whl/cu126
  uv pip install --python "${TRAIN_ENV}/bin/python" transformers flash-attn torchmetrics typer rich pydantic tqdm tensorboard --no-build-isolation
fi

if [[ "${INSTALL_MINI_ENV}" == "1" ]]; then
  uv venv --python 3.12 "${MINI_ENV}"
  uv pip install --python "${MINI_ENV}/bin/python" -e "${PROJECT_ROOT}/downstream_eval/multi_turn/swebench/mini-swe-agent--with-pruning"
fi

if [[ "${DOWNLOAD_MODELS}" == "1" ]]; then
  if ! has_real_safetensors "${PRUNER_MODEL_DIR}/model.safetensors"; then
    "${PRUNER_ENV}/bin/huggingface-cli" download "${PRUNER_MODEL_REPO}" --local-dir "${PRUNER_MODEL_DIR}" --local-dir-use-symlinks False
  fi
fi

if [[ "${DOWNLOAD_BASE_MODEL}" == "1" ]]; then
  "${PRUNER_ENV}/bin/huggingface-cli" download "${BASE_MODEL_REPO}" --local-dir "${BASE_MODEL_DIR}" --local-dir-use-symlinks False
fi

cat > "${PROJECT_ROOT}/.env.server" <<EOF
PROJECT_NAME=${PROJECT_NAME}
PROJECT_ROOT=${PROJECT_ROOT}
DATA_DIR=${DATA_DIR}
RUNS_DIR=${RUNS_DIR}
MODELS_DIR=${MODELS_DIR}
LOG_DIR=${LOG_DIR}
HF_ENDPOINT=${HF_ENDPOINT}
HF_HOME=${HF_HOME}
HUGGINGFACE_HUB_CACHE=${HUGGINGFACE_HUB_CACHE}
TRANSFORMERS_CACHE=${TRANSFORMERS_CACHE}
PRUNER_ENV=${PRUNER_ENV}
TRAIN_ENV=${TRAIN_ENV}
MINI_ENV=${MINI_ENV}
SWEPRUNER_MODEL_PATH=${PRUNER_MODEL_DIR}
BASE_MODEL=${BASE_MODEL_REPO}
BASE_MODEL_DIR=${BASE_MODEL_DIR}
PRUNER_PORT=8000
PRUNER_URL=http://127.0.0.1:8000/prune
EOF

echo "Bootstrap complete."
echo "Project root: ${PROJECT_ROOT}"
echo "Environment file: ${PROJECT_ROOT}/.env.server"
echo "Pruner model path: ${PRUNER_MODEL_DIR}"
