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
TRAIN_JSONL="${TRAIN_JSONL:-${DATA_DIR}/swe-pruner-training-dataset-py.jsonl}"
BASE_MODEL="${BASE_MODEL:-Qwen/Qwen3-Reranker-0.6B}"
BASE_MODEL_DIR="${BASE_MODEL_DIR:-${PROJECT_ROOT}/models/Qwen3-Reranker-0.6B}"

if [[ -d "${BASE_MODEL_DIR}" && -f "${BASE_MODEL_DIR}/config.json" ]]; then
  BASE_MODEL="${BASE_MODEL_DIR}"
fi

if [[ ! -f "${TRAIN_JSONL}" ]]; then
  echo "Missing training data: ${TRAIN_JSONL}" >&2
  echo "Put the labeled JSONL there or set TRAIN_JSONL=/path/to/file.jsonl." >&2
  exit 1
fi

NUM_GPUS="${NUM_GPUS:-1}"
CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-${GPU_ID:-0}}"
export CUDA_VISIBLE_DEVICES

STAMP="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="${LOG_DIR:-${RUNS_DIR}/train_span_ffn_focal/${STAMP}}"
mkdir -p "${LOG_DIR}"

PATH="${TRAIN_ENV}/bin:${PATH}"
export PATH

bash "${PROJECT_ROOT}/train/train_llm.sh" "${NUM_GPUS}" "${TRAIN_JSONL}" \
  --model-name "${BASE_MODEL}" \
  --epochs "${EPOCHS:-3}" \
  --lr "${LR:-1e-4}" \
  --log-dir "${LOG_DIR}" \
  --num-finetune-layers "${NUM_FINETUNE_LAYERS:-2}" \
  --num-fusion-layers "${NUM_FUSION_LAYERS:-1}" \
  --batch-size "${BATCH_SIZE:-4}" \
  --compression-head-type "${COMPRESSION_HEAD_TYPE:-ffn}" \
  --compression-loss-type "${COMPRESSION_LOSS_TYPE:-focal}" \
  --focal-alpha "${FOCAL_ALPHA:-0.65}" \
  --focal-gamma "${FOCAL_GAMMA:-2.0}" \
  --dropout "${DROPOUT:-0.4}" \
  --label-mode span \
  --span-merge-gap "${SPAN_MERGE_GAP:-3}" \
  --span-context-lines "${SPAN_CONTEXT_LINES:-1}" \
  --span-smooth-loss-weight "${SPAN_SMOOTH_LOSS_WEIGHT:-0.03}" \
  --use-multi-layer-fusion \
  --use-sample-level-aggregation

echo "Span-aware training run finished: ${LOG_DIR}"
