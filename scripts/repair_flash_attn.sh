#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
PRUNER_ENV="${PRUNER_ENV:-${PROJECT_ROOT}/.venv-pruner}"
TRAIN_ENV="${TRAIN_ENV:-${PROJECT_ROOT}/.venv-train}"
TORCH_VERSION="${TORCH_VERSION:-2.8.0+cu126}"
TORCHVISION_VERSION="${TORCHVISION_VERSION:-0.23.0+cu126}"
PYTORCH_INDEX_URL="${PYTORCH_INDEX_URL:-https://download.pytorch.org/whl/cu126}"
MAX_JOBS="${MAX_JOBS:-8}"

unset PYTHONHOME PYTHONPATH
export MAX_JOBS

install_flash_attn() {
  local env_dir="$1"
  if [[ ! -x "${env_dir}/bin/python" ]]; then
    echo "Skipping missing env: ${env_dir}" >&2
    return
  fi

  uv pip install --python "${env_dir}/bin/python" "torch==${TORCH_VERSION}" "torchvision==${TORCHVISION_VERSION}" --index-url "${PYTORCH_INDEX_URL}"
  uv pip install --python "${env_dir}/bin/python" wheel packaging ninja psutil
  uv pip install --python "${env_dir}/bin/python" flash-attn --no-build-isolation
  "${env_dir}/bin/python" - <<'PY'
import flash_attn
print("flash-attn import ok:", getattr(flash_attn, "__version__", "unknown"))
PY
}

install_flash_attn "${PRUNER_ENV}"
install_flash_attn "${TRAIN_ENV}"
