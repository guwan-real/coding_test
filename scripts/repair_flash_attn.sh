#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
PRUNER_ENV="${PRUNER_ENV:-${PROJECT_ROOT}/.venv-pruner}"
TRAIN_ENV="${TRAIN_ENV:-${PROJECT_ROOT}/.venv-train}"

unset PYTHONHOME PYTHONPATH

install_flash_attn() {
  local env_dir="$1"
  if [[ ! -x "${env_dir}/bin/python" ]]; then
    echo "Skipping missing env: ${env_dir}" >&2
    return
  fi

  uv pip install --python "${env_dir}/bin/python" wheel packaging ninja
  uv pip install --python "${env_dir}/bin/python" flash-attn --no-build-isolation
  "${env_dir}/bin/python" - <<'PY'
import flash_attn
print("flash-attn import ok:", getattr(flash_attn, "__version__", "unknown"))
PY
}

install_flash_attn "${PRUNER_ENV}"
install_flash_attn "${TRAIN_ENV}"
