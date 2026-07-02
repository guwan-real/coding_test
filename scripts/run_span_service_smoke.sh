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
SWEPRUNER_MODEL_PATH="${SWEPRUNER_MODEL_PATH:-${PROJECT_ROOT}/models/code-pruner}"
PRUNER_PORT="${PRUNER_PORT:-8000}"
GPU_ID="${GPU_ID:-0}"
LOG_DIR="${LOG_DIR:-${PROJECT_ROOT}/logs}"
PID_FILE="${LOG_DIR}/swe-pruner-${PRUNER_PORT}.pid"

mkdir -p "${LOG_DIR}"

health_ok() {
  curl -fsS "http://127.0.0.1:${PRUNER_PORT}/health" >/dev/null 2>&1
}

if ! health_ok; then
  CUDA_VISIBLE_DEVICES="${GPU_ID}" nohup "${PRUNER_ENV}/bin/swe-pruner" \
    --model-path "${SWEPRUNER_MODEL_PATH}" \
    --host 127.0.0.1 \
    --port "${PRUNER_PORT}" \
    > "${LOG_DIR}/swe-pruner-${PRUNER_PORT}.log" 2>&1 &
  echo "$!" > "${PID_FILE}"
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

export PRUNER_PORT
python3 - <<'PY'
import json
import os
import urllib.request

port = os.environ.get("PRUNER_PORT", "8000")
url = f"http://127.0.0.1:{port}/prune"
code = """\
def parse_user(raw):
    if raw is None:
        return None
    name = raw.strip()
    return {"name": name}

def write_user(path, data):
    with open(path, "w") as f:
        f.write(data["name"])
"""

def post(payload):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=180) as resp:
        return json.loads(resp.read().decode())

read_resp = post({
    "query": "Where is user input parsed?",
    "code": code,
    "selection_mode": "span",
    "operation_type": "read",
    "threshold": 0.5,
})
write_resp = post({
    "query": "Show the whole output before editing.",
    "code": code,
    "selection_mode": "span",
    "operation_type": "write",
    "threshold": 0.5,
})

assert read_resp["pruned_code"].strip(), "empty span-mode read response"
assert write_resp["pruned_code"] == code, "write operation must be protected from pruning"
print("Span smoke passed.")
print(f"Read tokens: {read_resp['origin_token_cnt']} -> {read_resp['left_token_cnt']}")
print(f"Write protection kept {len(write_resp['pruned_code'].splitlines())} lines.")
PY
