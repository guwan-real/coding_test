#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import random
from pathlib import Path
from typing import Any


def iter_traj_files(path: Path):
    if path.is_file():
        yield path
        return
    yield from sorted(path.rglob("*.traj.json"))


def normalize_kept_frags(value: Any) -> list[int]:
    if not isinstance(value, list):
        return []
    out = []
    for item in value:
        try:
            line = int(item)
        except (TypeError, ValueError):
            continue
        if line > 0:
            out.append(line)
    return sorted(set(out))


def load_json(path: Path) -> dict[str, Any] | None:
    try:
        data = json.loads(path.read_text())
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def iter_examples_from_traj(path: Path, min_chars: int, min_kept: int, max_keep_ratio: float):
    data = load_json(path)
    if not data:
        return
    instance_id = data.get("instance_id") or data.get("info", {}).get("instance_id")
    messages = data.get("messages", [])
    if not isinstance(messages, list):
        return

    for step_id, msg in enumerate(messages):
        if not isinstance(msg, dict):
            continue
        stats = msg.get("pruned_stats")
        if not isinstance(stats, dict):
            continue
        query = stats.get("query")
        code = stats.get("original_output")
        kept_frags = normalize_kept_frags(stats.get("kept_frags"))
        if not isinstance(query, str) or not query.strip():
            continue
        if not isinstance(code, str) or len(code) < min_chars:
            continue
        line_count = max(1, len(code.splitlines()))
        if len(kept_frags) < min_kept:
            continue
        if len(kept_frags) / line_count > max_keep_ratio:
            continue
        yield {
            "query": query.strip(),
            "code": code,
            "kept_frags": kept_frags,
            "score": float(stats.get("score") or 1.0),
            "source": "mini_swe_agent_pruner_trace",
            "instance_id": instance_id,
            "traj_path": str(path),
            "step_id": step_id,
            "operation_type": stats.get("operation_type"),
            "action": stats.get("action"),
            "origin_token_cnt": stats.get("origin_token_cnt"),
            "left_token_cnt": stats.get("left_token_cnt"),
        }


def main() -> None:
    parser = argparse.ArgumentParser(description="Build SWE-Pruner training JSONL from mini-SWE-agent trajectories.")
    parser.add_argument("--traj-dir", required=True, type=Path)
    parser.add_argument("--output-jsonl", required=True, type=Path)
    parser.add_argument("--min-chars", type=int, default=500)
    parser.add_argument("--min-kept", type=int, default=1)
    parser.add_argument("--max-keep-ratio", type=float, default=0.95)
    parser.add_argument("--max-examples", type=int, default=0)
    parser.add_argument("--shuffle", action="store_true")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    examples = []
    for traj_file in iter_traj_files(args.traj_dir):
        examples.extend(
            iter_examples_from_traj(
                traj_file,
                min_chars=args.min_chars,
                min_kept=args.min_kept,
                max_keep_ratio=args.max_keep_ratio,
            )
        )

    if args.shuffle:
        rng = random.Random(args.seed)
        rng.shuffle(examples)
    if args.max_examples and args.max_examples > 0:
        examples = examples[: args.max_examples]

    args.output_jsonl.parent.mkdir(parents=True, exist_ok=True)
    with args.output_jsonl.open("w", encoding="utf-8") as f:
        for item in examples:
            f.write(json.dumps(item, ensure_ascii=False) + "\n")

    print(f"Wrote {len(examples)} examples to {args.output_jsonl}")


if __name__ == "__main__":
    main()
