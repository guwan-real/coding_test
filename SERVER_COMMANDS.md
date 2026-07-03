# Server Command Sheet

Project name: `span_swepruner`

Repository branch: `span-isolation-pilot`

Server layout:

```text
/home/yuantao/futao/span_swepruner/          # code
/home/yuantao/futao/span_swepruner/data/     # datasets and benchmark inputs
/home/yuantao/futao/span_swepruner/runs/     # training and evaluation outputs
/home/yuantao/futao/span_swepruner/models/   # model cache and local checkpoints
```

## 1. Pull the project

```bash
export PROJECT_NAME=span_swepruner
export PROJECT_ROOT=/home/yuantao/futao/${PROJECT_NAME}
mkdir -p /home/yuantao/futao
GIT_LFS_SKIP_SMUDGE=1 git clone -b span-isolation-pilot https://github.com/guwan-real/coding_test.git "${PROJECT_ROOT}"
cd "${PROJECT_ROOT}"
```

If the project already exists on the server, update it with:

```bash
export PROJECT_ROOT=/home/yuantao/futao/span_swepruner
cd "${PROJECT_ROOT}"
git fetch origin span-isolation-pilot
git checkout span-isolation-pilot
git pull --ff-only origin span-isolation-pilot
```

If the repository is private, use a token from your shell environment instead of writing it into the command history:

```bash
export GITHUB_TOKEN=your_token_here
GIT_LFS_SKIP_SMUDGE=1 git clone -b span-isolation-pilot "https://x-access-token:${GITHUB_TOKEN}@github.com/guwan-real/coding_test.git" "${PROJECT_ROOT}"
unset GITHUB_TOKEN
cd "${PROJECT_ROOT}"
```

## 2. Bootstrap environments and model paths

```bash
bash scripts/bootstrap_span_swepruner.sh
```

Optional switches:

```bash
DOWNLOAD_MODELS=0 bash scripts/bootstrap_span_swepruner.sh
INSTALL_TRAIN_ENV=0 INSTALL_MINI_ENV=0 bash scripts/bootstrap_span_swepruner.sh
```

## 3. Smoke test span pruning only

This checks the pruner service and the new span/protected-operation behavior. It does not call a solver API.

```bash
GPU_ID=0 PRUNER_PORT=8000 bash scripts/run_span_service_smoke.sh
```

## 4. Train the span-aware FFN/focal candidate

Place the labeled SWE-Pruner JSONL at:

```text
/home/yuantao/futao/span_swepruner/data/swe-pruner-training-dataset-py.jsonl
```

Then run:

```bash
CUDA_VISIBLE_DEVICES=0 NUM_GPUS=1 bash scripts/train_span_ffn_focal.sh
```

Useful overrides:

```bash
CUDA_VISIBLE_DEVICES=0,1 NUM_GPUS=2 BATCH_SIZE=8 EPOCHS=3 bash scripts/train_span_ffn_focal.sh
SPAN_MERGE_GAP=2 SPAN_CONTEXT_LINES=2 SPAN_SMOOTH_LOSS_WEIGHT=0.05 bash scripts/train_span_ffn_focal.sh
```

Outputs go to `runs/train_span_ffn_focal/<timestamp>/`.

The line-label baseline is still available:

```bash
CUDA_VISIBLE_DEVICES=0 NUM_GPUS=1 bash scripts/train_line_ffn_focal.sh
```

## 5. Run a one-instance SWE-bench pilot with span pruning

This requires Docker or Singularity, a solver API key, and a running pruner service. The script starts the pruner service if needed.

```bash
export OPENAI_API_KEY="${DASHSCOPE_API_KEY}"
export OPENAI_API_BASE=https://dashscope.aliyuncs.com/compatible-mode/v1
export SOLVER_MODEL=openai/qwen-plus
GPU_ID=0 LIMIT=1 WORKERS=1 bash scripts/run_swebench_span_pilot.sh
```

Outputs go to `runs/swebench_span_pilot/<timestamp>/`.
