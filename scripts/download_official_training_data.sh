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
TRAIN_ENV="${TRAIN_ENV:-${PROJECT_ROOT}/.venv-train}"
OUTPUT_JSONL="${OUTPUT_JSONL:-${DATA_DIR}/swe-pruner-training-dataset-py.jsonl}"
FILE_ID="${OFFICIAL_DATA_FILE_ID:-18g_kWeyvd8EICEDZcKylEEf8mnOFhwdi}"
FORCE="${FORCE:-0}"

mkdir -p "${DATA_DIR}"

if [[ ! -x "${TRAIN_ENV}/bin/python" ]]; then
  echo "Missing train environment: ${TRAIN_ENV}" >&2
  echo "Run bash scripts/bootstrap_span_swepruner.sh first." >&2
  exit 1
fi

if [[ -s "${OUTPUT_JSONL}" && "${FORCE}" != "1" ]]; then
  echo "Dataset already exists: ${OUTPUT_JSONL}"
  echo "Set FORCE=1 to re-download."
  exit 0
fi

uv pip install --python "${TRAIN_ENV}/bin/python" gdown

TMP_FILE="${OUTPUT_JSONL}.tmp"
rm -f "${TMP_FILE}"

env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  "${TRAIN_ENV}/bin/python" -m gdown \
  "https://drive.google.com/uc?id=${FILE_ID}" \
  -O "${TMP_FILE}"

python3 - "${TMP_FILE}" <<'PY'
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
print(f"validated {count} rows")
PY

mv "${TMP_FILE}" "${OUTPUT_JSONL}"
echo "Official training data ready: ${OUTPUT_JSONL}"
