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
RUNS_DIR="${RUNS_DIR:-${PROJECT_ROOT}/runs}"
TRAIN_ENV="${TRAIN_ENV:-${PROJECT_ROOT}/.venv-train}"
TRAIN_JSONL="${TRAIN_JSONL:-${DATA_DIR}/swepruner_repair_qwen35_train.jsonl}"
BASE_MODEL="${BASE_MODEL:-Qwen/Qwen3-Reranker-0.6B}"
BASE_MODEL_DIR="${BASE_MODEL_DIR:-${PROJECT_ROOT}/models/Qwen3-Reranker-0.6B}"

if [[ -d "${BASE_MODEL_DIR}" && -f "${BASE_MODEL_DIR}/config.json" ]]; then
  BASE_MODEL="${BASE_MODEL_DIR}"
else
  echo "Missing local base model: ${BASE_MODEL_DIR}" >&2
  echo "Run: bash ${PROJECT_ROOT}/scripts/download_base_model.sh" >&2
  exit 1
fi

if [[ ! -f "${TRAIN_JSONL}" ]]; then
  echo "Missing repair-aware training data: ${TRAIN_JSONL}" >&2
  echo "Run: bash ${PROJECT_ROOT}/scripts/run_repair_aware_pipeline.sh" >&2
  exit 1
fi

if [[ ! -x "${TRAIN_ENV}/bin/python" ]]; then
  echo "Missing train environment: ${TRAIN_ENV}" >&2
  echo "Run bash ${PROJECT_ROOT}/scripts/bootstrap_span_swepruner.sh first." >&2
  exit 1
fi

NUM_GPUS="${NUM_GPUS:-4}"
CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-${GPU_IDS:-2,3,4,5}}"
export CUDA_VISIBLE_DEVICES

STAMP="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="${LOG_DIR:-${RUNS_DIR}/train_repair_crf_focal/${STAMP}}"
mkdir -p "${LOG_DIR}"

PATH="${TRAIN_ENV}/bin:${PATH}"
export PATH

if ! "${TRAIN_ENV}/bin/python" - <<'PY' >/dev/null 2>&1
import tensorboard
import torchmetrics
import transformers
import typer
import rich
import pydantic
import tqdm
PY
then
  uv pip install --python "${TRAIN_ENV}/bin/python" \
    tensorboard torchmetrics transformers typer rich pydantic tqdm
fi

bash "${PROJECT_ROOT}/train/train_llm.sh" "${NUM_GPUS}" "${TRAIN_JSONL}" \
  --model-name "${BASE_MODEL}" \
  --epochs "${EPOCHS:-3}" \
  --lr "${LR:-1e-4}" \
  --log-dir "${LOG_DIR}" \
  --num-finetune-layers "${NUM_FINETUNE_LAYERS:-2}" \
  --num-fusion-layers "${NUM_FUSION_LAYERS:-1}" \
  --batch-size "${BATCH_SIZE:-4}" \
  --compression-head-type "${COMPRESSION_HEAD_TYPE:-crf}" \
  --compression-loss-type "${COMPRESSION_LOSS_TYPE:-focal}" \
  --focal-gamma "${FOCAL_GAMMA:-2.0}" \
  --dropout "${DROPOUT:-0.4}" \
  --attn-implementation "${ATTN_IMPLEMENTATION:-flash_attention_2}" \
  --label-mode "${LABEL_MODE:-line}" \
  --span-merge-gap "${SPAN_MERGE_GAP:-0}" \
  --span-context-lines "${SPAN_CONTEXT_LINES:-0}" \
  --auto-focal-alpha \
  --use-multi-layer-fusion \
  --use-sample-level-aggregation

echo "Repair-aware CRF training run finished: ${LOG_DIR}"
