#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


REQUIRED_FIELDS = {
    "instance_id",
    "repo",
    "base_commit",
    "problem_statement",
    "patch",
}


def normalize_split_name(split: str) -> str:
    if split in {"train", "dev", "test"}:
        return split
    raise SystemExit(f"Unsupported split: {split}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Download SWE-bench metadata and export JSONL for repair-aware labels.")
    parser.add_argument("--dataset", default="SWE-bench/SWE-bench")
    parser.add_argument("--split", default="train")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--max-samples", type=int, default=0)
    args = parser.parse_args()

    split = normalize_split_name(args.split)
    try:
        from datasets import load_dataset
    except ImportError as exc:
        raise SystemExit("Missing dependency: datasets. Install it with `uv pip install datasets`.") from exc

    print(
        json.dumps(
            {
                "stage": "download_swebench_start",
                "dataset": args.dataset,
                "split": split,
                "output": str(args.output),
                "max_samples": args.max_samples,
            },
            indent=2,
        ),
        flush=True,
    )
    ds = load_dataset(args.dataset, split=split)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    missing_counts: dict[str, int] = {}
    with args.output.open("w", encoding="utf-8") as f:
        for row in ds:
            obj: dict[str, Any] = dict(row)
            missing = sorted(field for field in REQUIRED_FIELDS if not obj.get(field))
            if missing:
                for field in missing:
                    missing_counts[field] = missing_counts.get(field, 0) + 1
                continue
            f.write(json.dumps(obj, ensure_ascii=False) + "\n")
            count += 1
            if args.max_samples and count >= args.max_samples:
                break
            if count % 200 == 0:
                print(
                    json.dumps(
                        {
                            "stage": "download_swebench_progress",
                            "written": count,
                        }
                    ),
                    flush=True,
                )

    print(
        json.dumps(
            {
                "stage": "download_swebench_done",
                "output": str(args.output),
                "written": count,
                "missing_counts": missing_counts,
            },
            indent=2,
        ),
        flush=True,
    )


if __name__ == "__main__":
    main()
