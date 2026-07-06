#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

from repair_context_utils import read_jsonl


def repo_to_dirname(repo: str) -> str:
    return repo.replace("/", "__")


def run(cmd: list[str], cwd: Path | None = None) -> None:
    print("+ " + " ".join(cmd), flush=True)
    subprocess.run(cmd, cwd=str(cwd) if cwd else None, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Clone unique repositories referenced by a SWE-bench JSONL.")
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--github-prefix", default="https://github.com")
    parser.add_argument("--direct", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--fetch", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--max-repos", type=int, default=0)
    args = parser.parse_args()

    repos = []
    seen = set()
    for row in read_jsonl(args.input):
        repo = row.get("repo")
        if not isinstance(repo, str) or "/" not in repo or repo in seen:
            continue
        seen.add(repo)
        repos.append(repo)
    if args.max_repos:
        repos = repos[: args.max_repos]

    args.repo_root.mkdir(parents=True, exist_ok=True)
    print(
        json.dumps(
            {
                "stage": "clone_swebench_repos_start",
                "input": str(args.input),
                "repo_root": str(args.repo_root),
                "repos": len(repos),
                "direct": args.direct,
            },
            indent=2,
        ),
        flush=True,
    )

    cloned = 0
    skipped = 0
    for idx, repo in enumerate(repos, 1):
        dest = args.repo_root / repo_to_dirname(repo)
        if (dest / ".git").exists():
            skipped += 1
            if args.fetch:
                git_cmd = ["git"]
                if args.direct:
                    git_cmd += ["-c", "http.proxy=", "-c", "https.proxy="]
                run(git_cmd + ["fetch", "--all", "--tags", "--prune"], cwd=dest)
            print(json.dumps({"stage": "clone_swebench_repos_progress", "idx": idx, "repo": repo, "status": "exists"}), flush=True)
            continue
        url = f"{args.github_prefix.rstrip('/')}/{repo}.git"
        git_cmd = ["git"]
        if args.direct:
            git_cmd += ["-c", "http.proxy=", "-c", "https.proxy="]
        run(git_cmd + ["clone", url, str(dest)])
        cloned += 1
        print(json.dumps({"stage": "clone_swebench_repos_progress", "idx": idx, "repo": repo, "status": "cloned"}), flush=True)

    print(
        json.dumps(
            {
                "stage": "clone_swebench_repos_done",
                "cloned": cloned,
                "skipped_existing": skipped,
                "repo_root": str(args.repo_root),
            },
            indent=2,
        ),
        flush=True,
    )


if __name__ == "__main__":
    main()
