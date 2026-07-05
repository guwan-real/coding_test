#!/usr/bin/env python3
from __future__ import annotations

import argparse
import random
from pathlib import Path
from typing import Any

from repair_context_utils import read_jsonl


def line_labels(metadata: dict[str, Any]) -> dict[int, str]:
    labels = {}
    for line in metadata.get("support_lines", []) or []:
        try:
            labels[int(line)] = "S"
        except (TypeError, ValueError):
            pass
    for line in metadata.get("core_lines", []) or []:
        try:
            labels[int(line)] = "C"
        except (TypeError, ValueError):
            pass
    return labels


def render_sample(row: dict[str, Any], idx: int, context: int) -> str:
    metadata = row.get("metadata") if isinstance(row.get("metadata"), dict) else {}
    labels = line_labels(metadata)
    code_lines = str(row.get("code", "")).splitlines()
    selected = set()
    for line in labels:
        for candidate in range(max(1, line - context), min(len(code_lines), line + context) + 1):
            selected.add(candidate)
    if not selected:
        selected = set(range(1, min(len(code_lines), 80) + 1))
    rendered = []
    prev = 0
    for line_no in sorted(selected):
        if prev and line_no > prev + 1:
            rendered.append("...")
        mark = labels.get(line_no, " ")
        rendered.append(f"{mark} {line_no:5d}: {code_lines[line_no - 1]}")
        prev = line_no
    query = str(row.get("query", "")).strip().replace("\n", " ")
    if len(query) > 800:
        query = query[:800] + "..."
    return "\n".join(
        [
            f"## Sample {idx}: {metadata.get('sample_id') or metadata.get('file_path') or 'unknown'}",
            "",
            f"- source: `{metadata.get('source')}`",
            f"- file: `{metadata.get('file_path')}`",
            f"- core_lines: `{metadata.get('core_lines', [])}`",
            f"- support_lines: `{metadata.get('support_lines', [])}`",
            f"- drop_regions: `{metadata.get('drop_regions', [])}`",
            f"- validation: `{metadata.get('validation', {})}`",
            "",
            "### Query",
            "",
            query,
            "",
            "### Labeled Code",
            "",
            "```text",
            "\n".join(rendered),
            "```",
            "",
        ]
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Render random repair-aware training labels for inspection.")
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--num-samples", type=int, default=50)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--context", type=int, default=3)
    args = parser.parse_args()

    rows = list(read_jsonl(args.input))
    rng = random.Random(args.seed)
    if len(rows) > args.num_samples:
        rows = rng.sample(rows, args.num_samples)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    content = ["# Repair-Aware Label Inspection", ""]
    for idx, row in enumerate(rows, 1):
        content.append(render_sample(row, idx, args.context))
    args.output.write_text("\n".join(content), encoding="utf-8")
    print(f"Wrote {len(rows)} samples to {args.output}")


if __name__ == "__main__":
    main()
