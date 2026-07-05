#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from repair_context_utils import normalize_lines, read_jsonl, write_jsonl


def export_one(row: dict[str, Any], score_default: float) -> dict[str, Any] | None:
    labels = row.get("validated_labels")
    if not isinstance(labels, dict):
        return None
    code = row.get("code")
    query = row.get("query")
    if not isinstance(code, str) or not isinstance(query, str):
        return None
    kept = normalize_lines(labels.get("kept_frags"))
    if not kept:
        return None
    metadata = {
        "source": row.get("source"),
        "sample_id": row.get("sample_id"),
        "instance_id": row.get("instance_id"),
        "repo": row.get("repo"),
        "base_commit": row.get("base_commit"),
        "file_path": row.get("file_path"),
        "teacher_model": row.get("teacher_model"),
        "core_lines": labels.get("core_lines", []),
        "support_lines": labels.get("support_lines", []),
        "drop_regions": labels.get("drop_regions", []),
        "overall_confidence": labels.get("overall_confidence", 0.0),
        "validation": labels.get("validation", {}),
        "seed_metadata": row.get("seed_metadata", {}),
    }
    return {
        "query": query,
        "code": code,
        "kept_frags": kept,
        "score": float(score_default),
        "metadata": metadata,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Export validated repair labels to SWE-Pruner training JSONL.")
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--score-default", type=float, default=1.0)
    args = parser.parse_args()

    rows = []
    skipped = 0
    for row in read_jsonl(args.input):
        exported = export_one(row, args.score_default)
        if exported:
            rows.append(exported)
        else:
            skipped += 1
    count = write_jsonl(args.output, rows)
    print(json.dumps({"written": count, "skipped": skipped, "output": str(args.output)}, indent=2))


if __name__ == "__main__":
    main()
