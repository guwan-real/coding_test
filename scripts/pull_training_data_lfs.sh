#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
DATA_PATH="${DATA_PATH:-data/swe-pruner-training-dataset-py.jsonl}"

cd "${PROJECT_ROOT}"

if ! command -v git-lfs >/dev/null 2>&1 && ! git lfs version >/dev/null 2>&1; then
  cat >&2 <<'EOF'
git-lfs is required to pull the training dataset.

Install one of:
  sudo apt-get update && sudo apt-get install -y git-lfs
  conda install -c conda-forge git-lfs

Then rerun this script.
EOF
  exit 1
fi

git lfs install --local
git lfs pull -I "${DATA_PATH}"
ls -lh "${DATA_PATH}"
