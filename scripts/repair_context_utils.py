#!/usr/bin/env python3
from __future__ import annotations

import ast
import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


SUPPORT_TYPE_PRIORITY = {
    "core_window": 0,
    "enclosing_scope": 1,
    "function_header": 2,
    "control_flow_boundary": 3,
    "class_context": 4,
    "imports": 5,
    "constants": 6,
    "helper_definition": 7,
    "negative_region": 99,
}


@dataclass(frozen=True)
class Region:
    id: str
    file_path: str
    start: int
    end: int
    type: str
    symbol: str | None = None
    reason_from_static_analysis: str | None = None
    contains_seed_core: bool = False

    def to_json(self) -> dict[str, Any]:
        data = {
            "id": self.id,
            "file_path": self.file_path,
            "start": self.start,
            "end": self.end,
            "type": self.type,
            "contains_seed_core": self.contains_seed_core,
        }
        if self.symbol:
            data["symbol"] = self.symbol
        if self.reason_from_static_analysis:
            data["reason_from_static_analysis"] = self.reason_from_static_analysis
        return data


def read_jsonl(path: Path) -> Iterable[dict[str, Any]]:
    with path.open("r", encoding="utf-8") as f:
        for line_no, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError as exc:
                raise SystemExit(f"{path}:{line_no}: invalid JSON: {exc}") from exc
            if not isinstance(obj, dict):
                raise SystemExit(f"{path}:{line_no}: JSONL row must be an object")
            yield obj


def write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with path.open("w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
            count += 1
    return count


def normalize_lines(lines: Any, max_line: int | None = None) -> list[int]:
    out = []
    if not isinstance(lines, list):
        return out
    for item in lines:
        try:
            line = int(item)
        except (TypeError, ValueError):
            continue
        if line <= 0:
            continue
        if max_line is not None and line > max_line:
            continue
        out.append(line)
    return sorted(set(out))


def line_count(code: str) -> int:
    return len(code.splitlines())


def clamp_span(start: int, end: int, max_line: int) -> tuple[int, int] | None:
    if max_line <= 0:
        return None
    start = max(1, int(start))
    end = min(max_line, int(end))
    if start > end:
        return None
    return start, end


def line_range(start: int, end: int) -> list[int]:
    return list(range(start, end + 1))


def lines_intersect_region(lines: set[int], start: int, end: int) -> bool:
    return any(start <= line <= end for line in lines)


def merge_line_sets(*line_sets: Iterable[int]) -> list[int]:
    merged: set[int] = set()
    for values in line_sets:
        merged.update(int(v) for v in values if int(v) > 0)
    return sorted(merged)


def find_repo_checkout(repo_root: Path | None, repo: str | None, instance_id: str | None) -> Path | None:
    if repo_root is None:
        return None
    candidates = []
    if repo:
        candidates.extend(
            [
                repo_root / repo,
                repo_root / repo.replace("/", "__"),
                repo_root / repo.replace("/", "_"),
                repo_root / repo.split("/")[-1],
            ]
        )
    if instance_id:
        prefix = instance_id.split("-")[0]
        candidates.extend([repo_root / instance_id, repo_root / prefix])
    candidates.append(repo_root)
    for candidate in candidates:
        if candidate.exists() and candidate.is_dir():
            return candidate
    return None


def maybe_checkout(repo_dir: Path, commit: str | None) -> None:
    if not commit:
        return
    subprocess.run(
        ["git", "-C", str(repo_dir), "checkout", "--quiet", commit],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )


DIFF_HEADER_RE = re.compile(r"^diff --git a/(.*?) b/(.*?)$")
HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def parse_unified_diff(patch: str, context_lines: int = 1) -> dict[str, dict[str, Any]]:
    files: dict[str, dict[str, Any]] = {}
    current_file: str | None = None
    old_line = 0
    active_hunk: dict[str, Any] | None = None

    for raw in patch.splitlines():
        header = DIFF_HEADER_RE.match(raw)
        if header:
            current_file = header.group(2)
            files.setdefault(current_file, {"seed_core_lines": set(), "patch_hunks": []})
            active_hunk = None
            continue
        if current_file is None:
            continue
        if raw.startswith("+++ b/"):
            current_file = raw[len("+++ b/") :]
            files.setdefault(current_file, {"seed_core_lines": set(), "patch_hunks": []})
            continue
        if raw.startswith("--- ") or raw.startswith("index ") or raw.startswith("new file mode"):
            continue
        hunk = HUNK_RE.match(raw)
        if hunk:
            old_start = int(hunk.group(1))
            old_count = int(hunk.group(2) or "1")
            new_start = int(hunk.group(3))
            new_count = int(hunk.group(4) or "1")
            old_line = old_start
            active_hunk = {
                "old_start": old_start,
                "old_end": old_start + max(old_count, 1) - 1,
                "new_start": new_start,
                "new_end": new_start + max(new_count, 1) - 1,
            }
            files[current_file]["patch_hunks"].append(active_hunk)
            continue
        if active_hunk is None:
            continue
        if raw.startswith("\\"):
            continue
        if raw.startswith(" "):
            old_line += 1
            continue
        if raw.startswith("-"):
            for line in range(old_line - context_lines, old_line + context_lines + 1):
                if line > 0:
                    files[current_file]["seed_core_lines"].add(line)
            old_line += 1
            continue
        if raw.startswith("+"):
            anchor = max(1, old_line)
            for line in range(anchor - context_lines, anchor + context_lines + 1):
                if line > 0:
                    files[current_file]["seed_core_lines"].add(line)
            continue

    normalized: dict[str, dict[str, Any]] = {}
    for path, data in files.items():
        if path == "/dev/null":
            continue
        normalized[path] = {
            "seed_core_lines": sorted(data["seed_core_lines"]),
            "patch_hunks": data["patch_hunks"],
        }
    return normalized


def parse_python_ast(code: str) -> ast.AST | None:
    try:
        return ast.parse(code)
    except SyntaxError:
        return None


def node_span(node: ast.AST) -> tuple[int, int] | None:
    start = getattr(node, "lineno", None)
    end = getattr(node, "end_lineno", None)
    if not isinstance(start, int) or not isinstance(end, int):
        return None
    if start <= 0 or end < start:
        return None
    return start, end


def node_name(node: ast.AST) -> str | None:
    return getattr(node, "name", None)


def is_scope_node(node: ast.AST) -> bool:
    return isinstance(
        node,
        (
            ast.FunctionDef,
            ast.AsyncFunctionDef,
            ast.ClassDef,
        ),
    )


def collect_scope_nodes(tree: ast.AST) -> list[ast.AST]:
    nodes = [node for node in ast.walk(tree) if is_scope_node(node) and node_span(node)]
    return sorted(nodes, key=lambda n: (node_span(n)[1] - node_span(n)[0], node_span(n)[0]))


def find_smallest_containing(nodes: list[ast.AST], seed_lines: set[int], kinds: tuple[type, ...] | None = None) -> ast.AST | None:
    for node in nodes:
        if kinds and not isinstance(node, kinds):
            continue
        span = node_span(node)
        if span and lines_intersect_region(seed_lines, span[0], span[1]):
            return node
    return None


def function_header_span(node: ast.AST, max_line: int) -> tuple[int, int] | None:
    span = node_span(node)
    if not span:
        return None
    start, end = span
    body = getattr(node, "body", [])
    if body:
        first_body_line = getattr(body[0], "lineno", start)
        if (
            isinstance(body[0], ast.Expr)
            and isinstance(getattr(body[0], "value", None), ast.Constant)
            and isinstance(body[0].value.value, str)
            and getattr(body[0], "end_lineno", None)
        ):
            end = int(body[0].end_lineno)
        else:
            end = max(start, int(first_body_line) - 1)
    return clamp_span(start, min(end, start + 8), max_line)


def import_spans(tree: ast.AST, max_line: int) -> list[tuple[int, int]]:
    spans = []
    for node in getattr(tree, "body", []):
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            span = node_span(node)
            if span:
                spans.append(span)
    return merge_spans(spans, max_gap=1, max_line=max_line)


def constant_spans(tree: ast.AST, max_line: int) -> list[tuple[int, int]]:
    spans = []
    for node in getattr(tree, "body", []):
        names = []
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    names.append(target.id)
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            names.append(node.target.id)
        if names and any(name.isupper() for name in names):
            span = node_span(node)
            if span:
                spans.append(span)
    return merge_spans(spans, max_gap=1, max_line=max_line)


def merge_spans(spans: list[tuple[int, int]], max_gap: int, max_line: int) -> list[tuple[int, int]]:
    normalized = []
    for start, end in spans:
        clamped = clamp_span(start, end, max_line)
        if clamped:
            normalized.append(clamped)
    normalized.sort()
    merged: list[list[int]] = []
    for start, end in normalized:
        if not merged or start > merged[-1][1] + max_gap + 1:
            merged.append([start, end])
        else:
            merged[-1][1] = max(merged[-1][1], end)
    return [(start, end) for start, end in merged]


def called_names_in_lines(tree: ast.AST, start: int, end: int) -> set[str]:
    names = set()
    for node in ast.walk(tree):
        span = node_span(node)
        if not span or span[1] < start or span[0] > end:
            continue
        if isinstance(node, ast.Call):
            func = node.func
            if isinstance(func, ast.Name):
                names.add(func.id)
            elif isinstance(func, ast.Attribute):
                names.add(func.attr)
    return names


CONTROL_FLOW_TYPES = (ast.If, ast.For, ast.AsyncFor, ast.While, ast.Try, ast.With, ast.AsyncWith, ast.Match)


def build_candidate_regions(
    *,
    code: str,
    file_path: str,
    seed_core_lines: list[int],
    core_window: int = 6,
    max_enclosing_scope_lines: int = 120,
    max_helper_regions: int = 3,
    negative_regions: int = 2,
) -> list[dict[str, Any]]:
    max_line = line_count(code)
    seed_lines = set(normalize_lines(seed_core_lines, max_line=max_line))
    if not seed_lines:
        return []

    tree = parse_python_ast(code)
    regions: list[Region] = []

    def add_region(
        region_id: str,
        start: int,
        end: int,
        region_type: str,
        symbol: str | None = None,
        reason: str | None = None,
    ) -> None:
        clamped = clamp_span(start, end, max_line)
        if not clamped:
            return
        start2, end2 = clamped
        regions.append(
            Region(
                id=region_id,
                file_path=file_path,
                start=start2,
                end=end2,
                type=region_type,
                symbol=symbol,
                reason_from_static_analysis=reason,
                contains_seed_core=lines_intersect_region(seed_lines, start2, end2),
            )
        )

    add_region(
        "R_core",
        min(seed_lines) - core_window,
        max(seed_lines) + core_window,
        "core_window",
        reason="window around gold-patch or existing-pruner seed lines",
    )

    if tree is not None:
        scopes = collect_scope_nodes(tree)
        enclosing_scope = find_smallest_containing(
            scopes,
            seed_lines,
            kinds=(ast.FunctionDef, ast.AsyncFunctionDef),
        )
        enclosing_class = find_smallest_containing(scopes, seed_lines, kinds=(ast.ClassDef,))
        if enclosing_scope is None:
            enclosing_scope = find_smallest_containing(scopes, seed_lines)
        if enclosing_scope is not None:
            start, end = node_span(enclosing_scope) or (0, 0)
            if end - start + 1 <= max_enclosing_scope_lines:
                add_region(
                    "R_scope",
                    start,
                    end,
                    "enclosing_scope",
                    symbol=node_name(enclosing_scope),
                    reason="smallest function/method/class containing seed core lines",
                )
            else:
                add_region(
                    "R_scope",
                    max(min(seed_lines) - core_window, start),
                    min(max(seed_lines) + core_window, end),
                    "enclosing_scope",
                    symbol=node_name(enclosing_scope),
                    reason="enclosing scope is long; clipped around seed core lines",
                )
            header = function_header_span(enclosing_scope, max_line)
            if header:
                add_region(
                    "R_header",
                    header[0],
                    header[1],
                    "function_header",
                    symbol=node_name(enclosing_scope),
                    reason="signature/decorators/docstring of the enclosing repair scope",
                )

        if enclosing_class is not None:
            cls_start, cls_end = node_span(enclosing_class) or (0, 0)
            add_region(
                "R_class",
                cls_start,
                min(cls_start + 20, cls_end),
                "class_context",
                symbol=node_name(enclosing_class),
                reason="class header and early attributes for the patched method",
            )

        for idx, (start, end) in enumerate(import_spans(tree, max_line), 1):
            add_region(f"R_imports_{idx}", start, end, "imports", reason="module imports")

        for idx, (start, end) in enumerate(constant_spans(tree, max_line), 1):
            add_region(f"R_constants_{idx}", start, end, "constants", reason="module-level constants")

        control_nodes = []
        for node in ast.walk(tree):
            if not isinstance(node, CONTROL_FLOW_TYPES):
                continue
            span = node_span(node)
            if span and lines_intersect_region(seed_lines, span[0], span[1]):
                control_nodes.append(node)
        control_nodes.sort(key=lambda n: (node_span(n)[1] - node_span(n)[0], node_span(n)[0]))
        for idx, node in enumerate(control_nodes[:3], 1):
            start, end = node_span(node) or (0, 0)
            add_region(
                f"R_control_{idx}",
                start,
                min(end, start + 40),
                "control_flow_boundary",
                symbol=type(node).__name__,
                reason="control-flow construct containing seed core lines",
            )

        helper_names: set[str] = set()
        helper_scan_start = min(seed_lines)
        helper_scan_end = max(seed_lines)
        if enclosing_scope is not None:
            span = node_span(enclosing_scope)
            if span:
                helper_scan_start, helper_scan_end = span
        helper_names.update(called_names_in_lines(tree, helper_scan_start, helper_scan_end))
        helper_count = 0
        for node in scopes:
            if helper_count >= max_helper_regions:
                break
            if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            name = node_name(node)
            span = node_span(node)
            if not name or name not in helper_names or not span:
                continue
            if lines_intersect_region(seed_lines, span[0], span[1]):
                continue
            helper_count += 1
            add_region(
                f"R_helper_{helper_count}",
                span[0],
                min(span[1], span[0] + max_enclosing_scope_lines - 1),
                "helper_definition",
                symbol=name,
                reason="same-file helper called by the repair scope",
            )

        neg_count = 0
        for node in scopes:
            if neg_count >= negative_regions:
                break
            span = node_span(node)
            if not span or lines_intersect_region(seed_lines, span[0], span[1]):
                continue
            if abs(span[0] - min(seed_lines)) < core_window * 3:
                continue
            neg_count += 1
            add_region(
                f"R_neg_{neg_count}",
                span[0],
                min(span[1], span[0] + 80),
                "negative_region",
                symbol=node_name(node),
                reason="distant same-file scope used as a hard negative",
            )

    return dedupe_regions(regions)


def dedupe_regions(regions: list[Region]) -> list[dict[str, Any]]:
    seen: set[tuple[str, int, int, str]] = set()
    out = []
    used_ids: set[str] = set()
    for region in regions:
        key = (region.file_path, region.start, region.end, region.type)
        if key in seen:
            continue
        seen.add(key)
        data = region.to_json()
        if data["id"] in used_ids:
            suffix = 2
            base_id = data["id"]
            while f"{base_id}_{suffix}" in used_ids:
                suffix += 1
            data["id"] = f"{base_id}_{suffix}"
        used_ids.add(data["id"])
        out.append(data)
    out.sort(key=lambda r: (SUPPORT_TYPE_PRIORITY.get(r["type"], 50), r["start"], r["end"]))
    return out


def render_numbered_code(
    code: str,
    candidate_regions: list[dict[str, Any]] | None = None,
    max_code_lines: int = 1200,
) -> str:
    lines = code.splitlines()
    if len(lines) <= max_code_lines:
        selected = set(range(1, len(lines) + 1))
    else:
        selected = set()
        for region in candidate_regions or []:
            start = int(region.get("start", 1))
            end = int(region.get("end", start))
            for line in range(max(1, start - 2), min(len(lines), end + 2) + 1):
                selected.add(line)
    rendered = []
    prev = 0
    for line_no in sorted(selected):
        if line_no < 1 or line_no > len(lines):
            continue
        if prev and line_no > prev + 1:
            rendered.append("...")
        rendered.append(f"{line_no:5d}: {lines[line_no - 1]}")
        prev = line_no
    return "\n".join(rendered)


def deterministic_fallback_labels(
    sample: dict[str, Any],
    max_support_lines: int = 200,
) -> dict[str, Any]:
    max_line = line_count(str(sample.get("code", "")))
    seed = normalize_lines(sample.get("seed_core_lines"), max_line=max_line)
    seed_set = set(seed)
    core_lines = set(seed)
    support_lines: set[int] = set()
    region_labels = []
    drop_regions = []
    for region in sample.get("candidate_regions", []):
        rid = region.get("id")
        rtype = region.get("type")
        start = int(region.get("start", 1))
        end = int(region.get("end", start))
        region_lines = set(range(max(1, start), min(max_line, end) + 1))
        if rtype == "core_window" or region.get("contains_seed_core"):
            label = "CORE" if region_lines & seed_set else "SUPPORT"
            keep = sorted(region_lines if label == "CORE" else region_lines - seed_set)
        elif rtype in {"function_header", "imports", "constants", "control_flow_boundary", "class_context"}:
            label = "SUPPORT"
            keep = sorted(region_lines)
        else:
            label = "DROP"
            keep = []
        if label == "CORE":
            core_lines.update(keep)
        elif label == "SUPPORT":
            support_lines.update(keep)
        else:
            drop_regions.append(rid)
        region_labels.append(
            {
                "id": rid,
                "label": label,
                "keep_lines": keep,
                "reason": "deterministic fallback",
                "confidence": 0.0,
            }
        )

    support_lines -= core_lines
    if len(support_lines) > max_support_lines:
        support_lines = set(sorted(support_lines)[:max_support_lines])
    kept = merge_line_sets(core_lines, support_lines)
    return {
        "core_lines": sorted(core_lines),
        "support_lines": sorted(support_lines),
        "kept_frags": kept,
        "drop_regions": sorted(set(str(x) for x in drop_regions if x)),
        "region_labels": region_labels,
        "overall_confidence": 0.0,
        "fallback": True,
    }
