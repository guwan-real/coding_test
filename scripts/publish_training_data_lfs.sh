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
DATA_FILE="${DATA_FILE:-${DATA_DIR}/swe-pruner-training-dataset-py.jsonl}"
REMOTE="${REMOTE:-origin}"
BRANCH="${BRANCH:-span-isolation-pilot}"
COMMIT_MESSAGE="${COMMIT_MESSAGE:-Add official SWE-Pruner training data}"

cd "${PROJECT_ROOT}"

if ! command -v git-lfs >/dev/null 2>&1 && ! git lfs version >/dev/null 2>&1; then
  cat >&2 <<'EOF'
git-lfs is required to publish this dataset.

Install one of:
  sudo apt-get update && sudo apt-get install -y git-lfs
  conda install -c conda-forge git-lfs

Then rerun this script.
EOF
  exit 1
fi

if [[ ! -s "${DATA_FILE}" ]]; then
  echo "Missing dataset: ${DATA_FILE}" >&2
  echo "Download or place the official JSONL there first." >&2
  exit 1
fi

python3 - "${DATA_FILE}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
required = {"query", "code", "kept_frags", "score"}
count = 0
with path.open("r", encoding="utf-8") as f:
    for idx, line in enumerate(f, 1):
        if not line.strip():
            continue
        obj = json.loads(line)
        missing = required - set(obj)
        if missing:
            raise SystemExit(f"{path}:{idx} missing fields: {sorted(missing)}")
        if not isinstance(obj["kept_frags"], list):
            raise SystemExit(f"{path}:{idx} kept_frags must be a list")
        count += 1
if count == 0:
    raise SystemExit(f"{path}: no valid rows")
print(f"validated {count} rows: {path}")
PY

git lfs install --local
git lfs track "data/swe-pruner-training-dataset-py.jsonl"
git add .gitattributes "${DATA_FILE}"

if git diff --cached --quiet; then
  echo "No dataset changes to commit."
else
  git commit -m "${COMMIT_MESSAGE}"
fi

git push "${REMOTE}" "${BRANCH}"
echo "Published dataset through Git LFS: ${DATA_FILE}"
