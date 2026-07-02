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

PRUNER_ENV="${PRUNER_ENV:-${PROJECT_ROOT}/.venv-pruner}"
MINI_ENV="${MINI_ENV:-${PROJECT_ROOT}/.venv-mini}"
SWEPRUNER_MODEL_PATH="${SWEPRUNER_MODEL_PATH:-${PROJECT_ROOT}/models/code-pruner}"
RUNS_DIR="${RUNS_DIR:-${PROJECT_ROOT}/runs}"
LOG_DIR="${LOG_DIR:-${PROJECT_ROOT}/logs}"
PRUNER_PORT="${PRUNER_PORT:-8000}"
PRUNER_URL="${PRUNER_URL:-http://127.0.0.1:${PRUNER_PORT}/prune}"
GPU_ID="${GPU_ID:-0}"
OPENAI_API_KEY="${OPENAI_API_KEY:-${DASHSCOPE_API_KEY:-}}"
OPENAI_API_BASE="${OPENAI_API_BASE:-https://dashscope.aliyuncs.com/compatible-mode/v1}"
SOLVER_MODEL="${SOLVER_MODEL:-openai/qwen-plus}"

if [[ -z "${OPENAI_API_KEY}" ]]; then
  echo "Set OPENAI_API_KEY or DASHSCOPE_API_KEY before running the SWE-bench pilot." >&2
  exit 1
fi

mkdir -p "${LOG_DIR}" "${RUNS_DIR}"

health_ok() {
  curl -fsS "http://127.0.0.1:${PRUNER_PORT}/health" >/dev/null 2>&1
}

if ! health_ok; then
  CUDA_VISIBLE_DEVICES="${GPU_ID}" nohup "${PRUNER_ENV}/bin/swe-pruner" \
    --model-path "${SWEPRUNER_MODEL_PATH}" \
    --host 127.0.0.1 \
    --port "${PRUNER_PORT}" \
    > "${LOG_DIR}/swe-pruner-${PRUNER_PORT}.log" 2>&1 &
  echo "$!" > "${LOG_DIR}/swe-pruner-${PRUNER_PORT}.pid"
fi

for _ in $(seq 1 120); do
  if health_ok; then
    break
  fi
  sleep 2
done

health_ok || {
  echo "Pruner service did not become healthy. See ${LOG_DIR}/swe-pruner-${PRUNER_PORT}.log" >&2
  exit 1
}

STAMP="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${RUN_DIR:-${RUNS_DIR}/swebench_span_pilot/${STAMP}}"
CONFIG_FILE="${RUN_DIR}/pruner_span.yaml"
mkdir -p "${RUN_DIR}"

export PROJECT_ROOT RUN_DIR CONFIG_FILE OPENAI_API_KEY OPENAI_API_BASE SOLVER_MODEL PRUNER_URL

"${MINI_ENV}/bin/python" - <<'PY'
import os
from pathlib import Path
import yaml

project_root = Path(os.environ["PROJECT_ROOT"])
run_dir = Path(os.environ["RUN_DIR"])
template = project_root / "downstream_eval/multi_turn/swebench/mini-swe-agent--with-pruning/templates/pruner.yaml"
config_file = Path(os.environ["CONFIG_FILE"])

cfg = yaml.safe_load(template.read_text())
pruner = cfg.setdefault("agent", {}).setdefault("pruner", {})
pruner.update({
    "url": os.environ["PRUNER_URL"],
    "selection_mode": "span",
    "timeout": int(os.environ.get("PRUNER_TIMEOUT", "120")),
    "retries": int(os.environ.get("PRUNER_RETRIES", "3")),
    "min_chars": int(os.environ.get("PRUNER_MIN_CHARS", "500")),
    "threshold": float(os.environ.get("PRUNER_THRESHOLD", "0.5")),
})

model = cfg.setdefault("model", {})
model["model_name"] = os.environ["SOLVER_MODEL"]
model_kwargs = model.setdefault("model_kwargs", {})
model_kwargs["api_base"] = os.environ["OPENAI_API_BASE"]
model_kwargs["api_key"] = os.environ["OPENAI_API_KEY"]
model_kwargs["temperature"] = float(os.environ.get("TEMPERATURE", "0.0"))
if "litellm_model_registry" in model and str(model["litellm_model_registry"]).startswith("your_"):
    model.pop("litellm_model_registry")

cfg.setdefault("environment", {})["environment_class"] = os.environ.get("ENVIRONMENT_CLASS", "docker")
config_file.write_text(yaml.safe_dump(cfg, sort_keys=False))
PY

MSWEA_GLOBAL_CONFIG_DIR="${RUNS_DIR}/mswea_global" \
"${MINI_ENV}/bin/mini-extra" swebench \
  --subset "${SUBSET:-verified}" \
  --split "${SPLIT:-test}" \
  --slice "0:${LIMIT:-1}" \
  --output "${RUN_DIR}" \
  --workers "${WORKERS:-1}" \
  --config "${CONFIG_FILE}" \
  --environment-class "${ENVIRONMENT_CLASS:-docker}" \
  --model "${SOLVER_MODEL}"

echo "SWE-bench span pilot finished: ${RUN_DIR}"
