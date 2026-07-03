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

Run bootstrap from a clean shell when possible. If conda or another uv environment is active, deactivate it first:

```bash
conda deactivate || true
deactivate 2>/dev/null || true
unset VIRTUAL_ENV PYTHONHOME PYTHONPATH
```

```bash
bash scripts/bootstrap_span_swepruner.sh
```

Optional switches:

```bash
DOWNLOAD_MODELS=0 bash scripts/bootstrap_span_swepruner.sh
INSTALL_TRAIN_ENV=0 INSTALL_MINI_ENV=0 bash scripts/bootstrap_span_swepruner.sh
```

If an external SWE-Pruner service is already running, skip downloading the released pruner model and record the existing endpoint:

```bash
PRUNER_PORT=8001 PRUNER_URL=http://127.0.0.1:8001/prune DOWNLOAD_MODELS=0 bash scripts/bootstrap_span_swepruner.sh
```

`flash-attn` is required by the default training and serving commands. The scripts pin PyTorch to `2.8.0+cu126` to match available flash-attn wheels. If bootstrap was previously run with a newer torch and flash-attn failed, repair the partially-created environments with:

```bash
bash scripts/repair_flash_attn.sh
INSTALL_PRUNER_ENV=0 INSTALL_TRAIN_ENV=0 bash scripts/bootstrap_span_swepruner.sh
```

## 3. Smoke test span pruning only

This checks the pruner service and the new span/protected-operation behavior. It does not call a solver API.

```bash
PRUNER_PORT=8001 PRUNER_URL=http://127.0.0.1:8001/prune bash scripts/run_span_service_smoke.sh
```

## 4. Train the span-aware FFN/focal candidate

Prepare the labeled SWE-Pruner JSONL at:

```text
/home/yuantao/futao/span_swepruner/data/swe-pruner-training-dataset-py.jsonl
```

If you already have an official or custom JSONL file, standardize it with:

```bash
SOURCE_JSONL=/path/to/source.jsonl bash scripts/prepare_training_data.sh
```

If you collected mini-SWE-agent trajectories with pruner stats, build agent-native data and use it for training:

```bash
TRAJ_DIR=/home/yuantao/futao/span_swepruner/runs/swebench_span_pilot \
OUTPUT_JSONL=/home/yuantao/futao/span_swepruner/data/agent_span_data.jsonl \
bash scripts/build_agent_span_dataset.sh

AGENT_JSONL=/home/yuantao/futao/span_swepruner/data/agent_span_data.jsonl \
bash scripts/prepare_training_data.sh
```

To collect new agent-native span data from SWE-bench using the current pruner service:

```bash
export OPENAI_API_KEY="${DASHSCOPE_API_KEY}"
export OPENAI_API_BASE=https://dashscope.aliyuncs.com/compatible-mode/v1
export SOLVER_MODEL=openai/qwen-plus
PRUNER_PORT=8001 LIMIT=20 WORKERS=2 bash scripts/collect_agent_span_data.sh
```

You can also mix official and agent-native data:

```bash
SOURCE_JSONL=/path/to/official.jsonl \
AGENT_JSONL=/home/yuantao/futao/span_swepruner/data/agent_span_data.jsonl \
bash scripts/prepare_training_data.sh
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
