#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any

from repair_context_utils import (
    SUPPORT_TYPE_PRIORITY,
    deterministic_fallback_labels,
    line_count,
    merge_line_sets,
    normalize_lines,
    read_jsonl,
    write_jsonl,
)


VALID_LABELS = {"CORE", "SUPPORT", "DROP"}


def region_lines(region: dict[str, Any], max_line: int) -> set[int]:
    start = max(1, int(region.get("start", 1)))
    end = min(max_line, int(region.get("end", start)))
    if start > end:
        return set()
    return set(range(start, end + 1))


def cap_support_lines(
    support_lines: set[int],
    core_lines: set[int],
    candidate_regions: list[dict[str, Any]],
    max_support_lines: int,
    max_helper_regions: int,
) -> set[int]:
    support_lines -= core_lines
    if len(support_lines) <= max_support_lines:
        return support_lines

    helper_seen = 0
    ordered: list[int] = []
    seen = set()
    for region in sorted(
        candidate_regions,
        key=lambda r: (SUPPORT_TYPE_PRIORITY.get(str(r.get("type")), 50), int(r.get("start", 1))),
    ):
        if region.get("type") == "helper_definition":
            helper_seen += 1
            if helper_seen > max_helper_regions:
                continue
        start = int(region.get("start", 1))
        end = int(region.get("end", start))
        for line in range(start, end + 1):
            if line in support_lines and line not in seen:
                ordered.append(line)
                seen.add(line)
            if len(ordered) >= max_support_lines:
                return set(ordered)
    return set(sorted(support_lines)[:max_support_lines])


def validate_one(row: dict[str, Any], args: argparse.Namespace) -> tuple[dict[str, Any] | None, dict[str, Any] | None, list[str]]:
    reasons = []
    max_line = line_count(str(row.get("code", "")))
    seed = set(normalize_lines(row.get("seed_core_lines"), max_line=max_line))
    regions = row.get("candidate_regions")
    teacher = row.get("teacher_output")
    if not isinstance(regions, list) or not regions:
        reasons.append("missing_candidate_regions")
    if not seed:
        reasons.append("missing_seed_core")
    if row.get("teacher_error"):
        reasons.append("teacher_error")
    if not isinstance(teacher, dict):
        reasons.append("invalid_teacher_json")

    region_by_id = {}
    for region in regions or []:
        rid = region.get("id")
        if rid:
            region_by_id[str(rid)] = region

    region_labels = []
    core_lines: set[int] = set()
    support_lines: set[int] = set()
    drop_regions = []

    if isinstance(teacher, dict):
        overall_confidence = teacher.get("overall_confidence", 0.0)
        try:
            overall_confidence_f = float(overall_confidence)
        except (TypeError, ValueError):
            overall_confidence_f = 0.0
        if overall_confidence_f < args.min_overall_confidence:
            reasons.append("low_confidence")
        teacher_regions = teacher.get("regions")
        if not isinstance(teacher_regions, list):
            reasons.append("missing_teacher_regions")
        else:
            seen_ids = set()
            for item in teacher_regions:
                if not isinstance(item, dict):
                    reasons.append("bad_region_item")
                    continue
                rid = str(item.get("id", ""))
                label = str(item.get("label", "")).upper()
                if rid not in region_by_id:
                    reasons.append("unknown_region_id")
                    continue
                if label not in VALID_LABELS:
                    reasons.append("bad_label")
                    continue
                seen_ids.add(rid)
                region = region_by_id[rid]
                allowed = region_lines(region, max_line)
                keep = normalize_lines(item.get("keep_lines"), max_line=max_line)
                if any(line not in allowed for line in keep):
                    reasons.append("out_of_range_lines")
                    keep = [line for line in keep if line in allowed]
                if label == "CORE":
                    core_lines.update(keep)
                elif label == "SUPPORT":
                    support_lines.update(keep)
                else:
                    drop_regions.append(rid)
                    keep = []
                region_labels.append(
                    {
                        "id": rid,
                        "label": label,
                        "keep_lines": keep,
                        "reason": item.get("reason"),
                        "confidence": item.get("confidence", 0.0),
                    }
                )
            missing_regions = set(region_by_id) - seen_ids
            if missing_regions:
                reasons.append("missing_region_classifications")

    core_lines.update(seed)
    if not core_lines:
        reasons.append("missing_core")
    if not seed.issubset(core_lines | support_lines):
        reasons.append("seed_core_not_retained")

    support_lines = cap_support_lines(
        support_lines,
        core_lines,
        regions or [],
        max_support_lines=args.max_support_lines_per_sample,
        max_helper_regions=args.max_helper_regions,
    )
    kept = merge_line_sets(core_lines, support_lines)

    is_valid = not reasons or set(reasons).issubset({"missing_region_classifications"})
    if not is_valid and args.fallback_invalid:
        fallback = deterministic_fallback_labels(row, max_support_lines=args.max_support_lines_per_sample)
        validated = dict(row)
        validated["validated_labels"] = fallback
        validated["validated_labels"]["validation"] = {
            "valid": True,
            "fallback": True,
            "original_reasons": sorted(set(reasons)),
        }
        return validated, None, reasons + ["fallback"]

    if not is_valid:
        rejected = dict(row)
        rejected["validation_errors"] = sorted(set(reasons))
        return None, rejected, reasons

    validated = dict(row)
    validated["validated_labels"] = {
        "core_lines": sorted(core_lines),
        "support_lines": sorted(support_lines),
        "kept_frags": kept,
        "drop_regions": sorted(set(drop_regions)),
        "region_labels": region_labels,
        "overall_confidence": teacher.get("overall_confidence", 0.0) if isinstance(teacher, dict) else 0.0,
        "fallback": False,
        "validation": {
            "valid": True,
            "fallback": False,
            "warnings": sorted(set(reasons)),
        },
    }
    return validated, None, reasons


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate teacher CORE/SUPPORT/DROP labels.")
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--reject-output", required=True, type=Path)
    parser.add_argument("--max-support-lines-per-sample", type=int, default=200)
    parser.add_argument("--max-helper-regions", type=int, default=3)
    parser.add_argument("--min-overall-confidence", type=float, default=0.0)
    parser.add_argument("--fallback-invalid", action=argparse.BooleanOptionalAction, default=True)
    args = parser.parse_args()

    valid_rows = []
    reject_rows = []
    stats = Counter()
    total = 0
    for row in read_jsonl(args.input):
        total += 1
        valid, reject, reasons = validate_one(row, args)
        for reason in set(reasons):
            stats[reason] += 1
        if valid:
            valid_rows.append(valid)
        if reject:
            reject_rows.append(reject)

    write_jsonl(args.output, valid_rows)
    write_jsonl(args.reject_output, reject_rows)
    summary = {
        "total": total,
        "valid": len(valid_rows),
        "reject": len(reject_rows),
        "stats": dict(sorted(stats.items())),
        "output": str(args.output),
        "reject_output": str(args.reject_output),
    }
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
