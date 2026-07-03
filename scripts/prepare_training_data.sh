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
TARGET_JSONL="${TARGET_JSONL:-${DATA_DIR}/swe-pruner-training-dataset-py.jsonl}"
mkdir -p "${DATA_DIR}"

validate_jsonl() {
  local path="$1"
  python3 - "$path" <<'PY'
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
print(f"validated {count} rows: {path}")
PY
}

TMP_LIST=()
if [[ -n "${SOURCE_JSONL:-}" ]]; then
  validate_jsonl "${SOURCE_JSONL}"
  TMP_LIST+=("${SOURCE_JSONL}")
fi

if [[ -n "${AGENT_JSONL:-}" ]]; then
  validate_jsonl "${AGENT_JSONL}"
  TMP_LIST+=("${AGENT_JSONL}")
fi

if [[ "${#TMP_LIST[@]}" -eq 0 ]]; then
  echo "Set SOURCE_JSONL=/path/to/official.jsonl and/or AGENT_JSONL=/path/to/agent_span_data.jsonl" >&2
  exit 1
fi

cat "${TMP_LIST[@]}" > "${TARGET_JSONL}"
validate_jsonl "${TARGET_JSONL}"
echo "Training data ready: ${TARGET_JSONL}"
