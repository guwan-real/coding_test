# Decision Log

## 2026-07-02 - Server project handoff

- Project name: `span_swepruner`.
- Server root: `/home/yuantao/futao/span_swepruner`.
- Code, data, run outputs, and model/cache paths are rooted under the project directory:
  - Code: `/home/yuantao/futao/span_swepruner/`
  - Data: `/home/yuantao/futao/span_swepruner/data/`
  - Runs: `/home/yuantao/futao/span_swepruner/runs/`
  - Models/cache: `/home/yuantao/futao/span_swepruner/models/`
- GitHub branch for server pull: `span-isolation-pilot` in `https://github.com/guwan-real/coding_test`.
- Command entrypoint: `SERVER_COMMANDS.md`.
- Server scripts:
  - `scripts/bootstrap_span_swepruner.sh`: creates project directories, virtual environments, cache paths, and downloads the released pruner model unless disabled.
  - `scripts/run_span_service_smoke.sh`: starts the pruner service and validates span-mode reads plus protected write operations without solver API calls.
  - `scripts/train_line_ffn_focal.sh`: launches the current line-label FFN/focal training candidate using project-local paths.
  - `scripts/run_swebench_span_pilot.sh`: runs a one-instance SWE-bench pilot with span-mode pruning and environment-supplied solver API credentials.
- Important scope note: span-aware training is now available through `scripts/train_span_ffn_focal.sh`. It converts sparse `kept_frags` into contiguous line-span labels, trains with the existing FFN/focal head, and adds an optional same-label smoothness regularizer. The line-label baseline remains available through `scripts/train_line_ffn_focal.sh`.

## 2026-07-03 - Agent-native data scripts

- Added trajectory-based data generation for cases where the official SWE-Pruner JSONL is unavailable.
- Future mini-SWE-agent trajectories now store pruner query, action, operation type, original output, pruned output, kept lines, and token counts inside `pruned_stats`.
- New scripts:
  - `scripts/build_agent_span_dataset.py`: converts `.traj.json` files with pruner stats into SWE-Pruner training JSONL rows.
  - `scripts/build_agent_span_dataset.sh`: server wrapper for trajectory-to-JSONL conversion.
  - `scripts/prepare_training_data.sh`: validates and combines official/custom JSONL and agent-native JSONL into `data/swe-pruner-training-dataset-py.jsonl`.
  - `scripts/collect_agent_span_data.sh`: runs a small SWE-bench span-pruning pilot and immediately converts the resulting trajectories into training data.
