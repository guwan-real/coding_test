#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from repair_context_utils import (
    build_candidate_regions,
    find_repo_checkout,
    line_count,
    maybe_checkout,
    normalize_lines,
    parse_unified_diff,
    read_jsonl,
)


def build_official_sample(row: dict[str, Any], idx: int, args: argparse.Namespace) -> dict[str, Any] | None:
    code = row.get("code")
    query = row.get("query")
    if not isinstance(code, str) or not isinstance(query, str):
        return None
    max_line = line_count(code)
    seed = normalize_lines(row.get("kept_frags"), max_line=max_line)
    if not seed:
        return None
    file_path = str(row.get("file_path") or row.get("metadata", {}).get("file_path") or f"official_sample_{idx}.py")
    regions = build_candidate_regions(
        code=code,
        file_path=file_path,
        seed_core_lines=seed,
        core_window=args.core_window,
        max_enclosing_scope_lines=args.max_enclosing_scope_lines,
        max_helper_regions=args.max_helper_regions,
        negative_regions=args.negative_regions,
    )
    if not regions:
        return None
    return {
        "sample_id": f"official_swepruner::{idx}",
        "source": "official_swepruner",
        "query": query,
        "file_path": file_path,
        "code": code,
        "seed_core_lines": seed,
        "seed_metadata": {
            "score": row.get("score"),
            "source": "official_kept_frags",
        },
        "candidate_regions": regions,
    }


def build_swebench_samples(row: dict[str, Any], idx: int, args: argparse.Namespace) -> list[dict[str, Any]]:
    patch = row.get("patch")
    query = row.get("problem_statement") or row.get("query")
    if not isinstance(patch, str) or not isinstance(query, str):
        return []
    instance_id = str(row.get("instance_id") or f"swebench_{idx}")
    repo = row.get("repo")
    base_commit = row.get("base_commit")
    repo_dir = find_repo_checkout(args.repo_root, repo, instance_id)
    if repo_dir is None:
        return []
    if args.checkout_base_commit:
        maybe_checkout(repo_dir, str(base_commit) if base_commit else None)

    parsed = parse_unified_diff(patch, context_lines=args.patch_context_lines)
    samples = []
    for file_path, patch_info in parsed.items():
        if args.lang == "python" and not file_path.endswith(".py"):
            continue
        file_on_disk = repo_dir / file_path
        if not file_on_disk.exists() or not file_on_disk.is_file():
            continue
        try:
            code = file_on_disk.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            code = file_on_disk.read_text(encoding="utf-8", errors="replace")
        max_line = line_count(code)
        seed = normalize_lines(patch_info.get("seed_core_lines"), max_line=max_line)
        if not seed:
            continue
        regions = build_candidate_regions(
            code=code,
            file_path=file_path,
            seed_core_lines=seed,
            core_window=args.core_window,
            max_enclosing_scope_lines=args.max_enclosing_scope_lines,
            max_helper_regions=args.max_helper_regions,
            negative_regions=args.negative_regions,
        )
        if not regions:
            continue
        samples.append(
            {
                "sample_id": f"{instance_id}::{file_path}",
                "instance_id": instance_id,
                "repo": repo,
                "base_commit": base_commit,
                "source": "swebench_patch",
                "query": query,
                "file_path": file_path,
                "code": code,
                "seed_core_lines": seed,
                "seed_metadata": {
                    "patch_hunks": patch_info.get("patch_hunks", []),
                    "source": "gold_patch",
                },
                "candidate_regions": regions,
            }
        )
    return samples


def main() -> None:
    parser = argparse.ArgumentParser(description="Build repair-aware CORE/SUPPORT candidate regions.")
    parser.add_argument("--source", required=True, choices=["swebench", "official_swepruner"])
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--repo-root", type=Path, default=None)
    parser.add_argument("--lang", default="python", choices=["python"])
    parser.add_argument("--checkout-base-commit", action="store_true")
    parser.add_argument("--patch-context-lines", type=int, default=1)
    parser.add_argument("--core-window", type=int, default=6)
    parser.add_argument("--max-enclosing-scope-lines", type=int, default=120)
    parser.add_argument("--max-helper-regions", type=int, default=3)
    parser.add_argument("--negative-regions", type=int, default=2)
    parser.add_argument("--max-samples", type=int, default=0)
    parser.add_argument("--progress-every", type=int, default=100)
    args = parser.parse_args()

    if args.source == "swebench" and args.repo_root is None:
        raise SystemExit("--repo-root is required for --source swebench")

    skipped = 0
    count = 0
    args.output.parent.mkdir(parents=True, exist_ok=True)
    print(
        json.dumps(
            {
                "stage": "build_candidates_start",
                "source": args.source,
                "input": str(args.input),
                "output": str(args.output),
                "max_samples": args.max_samples,
            },
            indent=2,
        ),
        flush=True,
    )
    with args.output.open("w", encoding="utf-8") as f:
        for idx, row in enumerate(read_jsonl(args.input), 1):
            if args.source == "official_swepruner":
                sample = build_official_sample(row, idx, args)
                samples = [sample] if sample else []
            else:
                samples = build_swebench_samples(row, idx, args)
            if samples:
                for sample in samples:
                    if sample is None:
                        continue
                    f.write(json.dumps(sample, ensure_ascii=False) + "\n")
                    count += 1
                    if args.max_samples and count >= args.max_samples:
                        break
            else:
                skipped += 1
            if args.progress_every > 0 and (idx % args.progress_every == 0 or count == args.max_samples):
                print(
                    json.dumps(
                        {
                            "stage": "build_candidates_progress",
                            "rows_read": idx,
                            "candidates_written": count,
                            "skipped_rows": skipped,
                        }
                    ),
                    flush=True,
                )
            if args.max_samples and count >= args.max_samples:
                break
    summary = {
        "stage": "build_candidates_done",
        "source": args.source,
        "input": str(args.input),
        "output": str(args.output),
        "written": count,
        "skipped_rows": skipped,
    }
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
