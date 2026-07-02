# Span-Isolated SWE-Pruner

Date: 2026-07-02

## Why

Line-level pruning can score well under supervised labels while still damaging SWE-bench solve quality,
because coding agents need coherent local evidence ranges rather than isolated high-scoring lines. This
variant keeps the existing SWE-Pruner scorer but changes the served output object to contiguous line
spans and protects operations whose outputs should not be pruned.

## Minimal implementation

- `selection_mode: line` remains the default and preserves previous behavior.
- `selection_mode: span` converts high-scoring seed lines into contiguous ranges.
- Mini-SWE-Agent classifies shell actions as `read`, `search`, `test`, `write`, `submit`, or `other`.
- In span mode, `write`, `edit`, `test`, and `submit` observations are returned unchanged.

Changed files:

- `swe-pruner/src/swe_pruner/prune_wrapper.py`
- `downstream_eval/multi_turn/swebench/mini-swe-agent--with-pruning/src/minisweagent/utils/pruner.py`
- `downstream_eval/multi_turn/swebench/mini-swe-agent--with-pruning/src/minisweagent/agents/default.py`
- `examples/pruner_span_released.example.yaml`

## Suggested pilot

Start released SWE-Pruner on an idle GPU:

```bash
cd swe-pruner
PYTHONPATH=src SWEPRUNER_MODEL_PATH=./model CUDA_VISIBLE_DEVICES=<GPU> \
  HF_HOME=/path/to/hf_home HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
  .venv-prune/bin/python -m swe_pruner.online_serving --host 127.0.0.1 --port 8051
```

Use a Mini-SWE-Agent config that includes:

```yaml
agent:
  pruner:
    url: http://127.0.0.1:8051/prune
    timeout: 120
    retries: 3
    min_chars: 500
    chunk_overlap_tokens: 50
    threshold: 0.5
    selection_mode: span
```

Evaluate with local SWE-bench images using `--namespace none`.

Success criterion for the first pilot: match or exceed released SWE-Pruner's solve count at similar token
scale. If span mode recovers solve but keeps too many tokens, add an explicit span-budget objective before
training a span head.

## Training direction

If post-processing works, train a span-aware variant:

- Convert line masks to contiguous span labels.
- Add operation namespaces: `read`, `search`, `traceback`, and protected write/test outputs.
- Prefer a start/end span head or semi-CRF span scorer over another independent line classifier.
- Add trajectory-evolved weak labels anchored in real evidence: final patch hunks, edited ranges,
  traceback locations, test failure locations, and repeated search/read references.
