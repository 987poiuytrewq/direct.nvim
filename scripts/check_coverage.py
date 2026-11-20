#!/usr/bin/env python3
"""Enforce aggregate and per-file LuaCov coverage budgets."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


SUMMARY_ROW = re.compile(r"^(?P<path>.+?)\s+(?P<hits>\d+)\s+(?P<missed>\d+)\s+(?P<coverage>\d+(?:\.\d+)?)%$")


def parse_summary(
    text: str,
    repo_root: Path | None = None,
) -> tuple[dict[str, dict[str, float | int]], float]:
    files: dict[str, dict[str, float | int]] = {}
    total: float | None = None
    root_prefix = None
    if repo_root is not None:
        root_prefix = repo_root.resolve().as_posix().rstrip("/") + "/"

    for raw_line in text.splitlines():
        match = SUMMARY_ROW.match(raw_line.strip())
        if not match:
            continue
        path = match.group("path").replace("\\", "/")
        root_matches = root_prefix is not None and path[:len(root_prefix)] == root_prefix
        if root_prefix is not None and os.name == "nt":
            root_matches = path[:len(root_prefix)].casefold() == root_prefix.casefold()
        if root_matches and root_prefix:
            path = path[len(root_prefix):]
        elif path.startswith("./"):
            path = path[2:]
        row: dict[str, float | int] = {
            "hits": int(match.group("hits")),
            "missed": int(match.group("missed")),
            "coverage": float(match.group("coverage")),
        }
        if path == "Total":
            total = float(row["coverage"])
        else:
            if path in files:
                raise ValueError(f"duplicate coverage row: {path}")
            files[path] = row

    if total is None:
        raise ValueError("coverage summary has no Total row")
    if not files:
        raise ValueError("coverage summary has no per-file rows")
    return files, total


def add_unreported_sources(
    files: dict[str, dict[str, float | int]],
    source_files: list[str],
) -> dict[str, dict[str, float | int]]:
    """Represent source files omitted by LuaCov (never loaded) at 0% coverage."""
    result = dict(files)
    for path in source_files:
        normalized = path.replace("\\", "/")
        result.setdefault(normalized, {"hits": 0, "missed": 0, "coverage": 0.0})
    return result


def tracked_source_files(repo_root: Path, source_roots: list[str]) -> list[str]:
    """Inventory tracked Lua sources in the same roots selected by LuaCov."""
    for source_root in source_roots:
        if not (repo_root / source_root).is_dir():
            raise ValueError(f"coverage source root does not exist: {source_root}")

    result = subprocess.run(
        ["git", "ls-files", "-z", "--", *source_roots],
        cwd=repo_root,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return sorted(
        path.replace("\\", "/")
        for path in os.fsdecode(result.stdout).split("\0")
        if path.endswith(".lua")
    )


def check_baseline_transition(
    previous: dict[str, Any],
    current: dict[str, Any],
) -> list[str]:
    """Reject weaker floors, lower exception figures, and allowlist growth."""
    errors: list[str] = []
    try:
        previous_floor = float(previous["file_floor"])
        current_floor = float(current["file_floor"])
    except (KeyError, TypeError, ValueError):
        return ["coverage baseline has an invalid file_floor"]
    if current_floor < previous_floor:
        errors.append(
            f"file floor decreased from {previous_floor:.2f}% to {current_floor:.2f}%"
        )

    previous_roots = set(previous.get("source_roots", []))
    current_roots = set(current.get("source_roots", []))
    for source_root in sorted(previous_roots - current_roots):
        errors.append(f"coverage source root was removed: {source_root}")

    previous_platforms = previous.get("platforms", {})
    current_platforms = current.get("platforms", {})
    if not isinstance(previous_platforms, dict) or not isinstance(current_platforms, dict):
        return errors + ["coverage baseline platforms must be objects"]

    for platform in sorted(set(previous_platforms) - set(current_platforms)):
        errors.append(f"coverage baseline removed platform profile {platform!r}")
    for platform in sorted(set(current_platforms) - set(previous_platforms)):
        errors.append(f"coverage baseline added platform profile {platform!r}")

    for platform in sorted(set(previous_platforms) & set(current_platforms)):
        old_profile = previous_platforms[platform]
        new_profile = current_platforms[platform]
        try:
            old_total = float(old_profile["total_floor"])
            new_total = float(new_profile["total_floor"])
        except (KeyError, TypeError, ValueError):
            errors.append(f"coverage baseline has an invalid total_floor for {platform!r}")
            continue
        if new_total < old_total:
            errors.append(
                f"{platform}: total floor decreased from {old_total:.2f}% to {new_total:.2f}%"
            )

        old_allowlist = old_profile.get("allowlist", {})
        new_allowlist = new_profile.get("allowlist", {})
        if not isinstance(old_allowlist, dict) or not isinstance(new_allowlist, dict):
            errors.append(f"{platform}: allowlists must be objects")
            continue
        for path in sorted(set(new_allowlist) - set(old_allowlist)):
            errors.append(f"{platform}: allowlist grew with new exception {path}")
        for path in sorted(set(old_allowlist) & set(new_allowlist)):
            try:
                old_coverage = float(old_allowlist[path])
                new_coverage = float(new_allowlist[path])
            except (TypeError, ValueError):
                errors.append(f"{platform}: invalid allowlist coverage for {path}")
                continue
            if new_coverage < old_coverage:
                errors.append(
                    f"{platform}: allowlist coverage decreased for {path} "
                    f"from {old_coverage:.2f}% to {new_coverage:.2f}%"
                )
    return errors


def evaluate(
    summary_text: str,
    policy: dict[str, Any],
    platform: str,
    source_files: list[str] | None = None,
    repo_root: Path | None = None,
) -> tuple[list[tuple[str, dict[str, float | int], str]], list[str], float]:
    files, total = parse_summary(summary_text, repo_root)
    files = add_unreported_sources(files, source_files or [])
    errors: list[str] = []
    profile = policy.get("platforms", {}).get(platform)
    if not isinstance(profile, dict):
        return (
            [(path, row, "unconfigured") for path, row in sorted(
                files.items(), key=lambda item: (float(item[1]["coverage"]), item[0])
            )],
            [f"no baseline configured for platform {platform!r}"],
            total,
        )

    try:
        floor = float(policy["file_floor"])
        total_floor = float(profile["total_floor"])
        measured_total = float(profile["measured_total"])
    except (KeyError, TypeError, ValueError) as error:
        return [], [f"invalid coverage policy for platform {platform!r}: {error}"], total

    allowlist = profile.get("allowlist", {})
    if not isinstance(allowlist, dict):
        return [], [f"allowlist for platform {platform!r} must be an object"], total

    rows: list[tuple[str, dict[str, float | int], str]] = []
    for path, row in sorted(files.items(), key=lambda item: (float(item[1]["coverage"]), item[0])):
        coverage = float(row["coverage"])
        baseline = allowlist.get(path)
        if coverage < floor:
            if baseline is None:
                state = "below floor"
                errors.append(
                    f"{path}: {coverage:.2f}% is below the {floor:.2f}% floor and is not allowlisted"
                )
            else:
                try:
                    baseline = round(float(baseline), 2)
                except (TypeError, ValueError):
                    state = "invalid baseline"
                    errors.append(f"{path}: allowlist baseline must be a coverage percentage")
                else:
                    if baseline >= floor:
                        state = "invalid baseline"
                        errors.append(
                            f"{path}: allowlist baseline {baseline:.2f}% must be below the {floor:.2f}% floor"
                        )
                    elif coverage < baseline:
                        state = f"regressed (baseline {baseline:.2f}%)"
                        errors.append(
                            f"{path}: coverage fell from allowlisted {baseline:.2f}% to {coverage:.2f}%"
                        )
                    elif coverage > baseline:
                        state = f"improved (raise baseline from {baseline:.2f}%)"
                        errors.append(
                            f"{path}: coverage rose from allowlisted {baseline:.2f}% to {coverage:.2f}%; "
                            "raise the baseline or remove the entry if it reaches the floor"
                        )
                    else:
                        state = f"allowlisted at {baseline:.2f}%"
        else:
            state = "at/above floor"
            if path in allowlist:
                errors.append(
                    f"{path}: coverage reached {coverage:.2f}%; remove its stale allowlist entry"
                )
        rows.append((path, row, state))

    for path in sorted(set(allowlist) - set(files)):
        errors.append(f"{path}: stale allowlist entry; file is missing from this platform's report")

    if total < total_floor:
        errors.append(f"total coverage {total:.2f}% is below the {total_floor:.2f}% platform floor")
    if total_floor >= measured_total:
        errors.append(
            f"{platform}: total floor {total_floor:.2f}% must be just below "
            f"the recorded measurement {measured_total:.2f}%"
        )
    return rows, errors, total


def markdown_table(
    rows: list[tuple[str, dict[str, float | int], str]],
    platform: str,
    total: float,
) -> str:
    lines = [
        f"## Per-file coverage ({platform})",
        "",
        f"Total: **{total:.2f}%**",
        "",
        "| File | Hits | Missed | Coverage | Policy |",
        "|---|---:|---:|---:|---|",
    ]
    for path, row, state in rows:
        lines.append(
            f"| `{path}` | {row['hits']} | {row['missed']} | {float(row['coverage']):.2f}% | {state} |"
        )
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", type=Path, default=Path("coverage/summary.out"))
    parser.add_argument("--baseline", type=Path, default=Path("scripts/coverage-baseline.json"))
    parser.add_argument("--previous-baseline", type=Path)
    parser.add_argument(
        "--check-baseline-only",
        action="store_true",
        help="check that a baseline update does not lower floors or grow exceptions",
    )
    parser.add_argument(
        "--report-only",
        action="store_true",
        help="publish a lowest-first table without enforcing a baseline",
    )
    parser.add_argument("--platform", default=os.environ.get("COVERAGE_PLATFORM", "local"))
    args = parser.parse_args(argv)

    try:
        policy = json.loads(args.baseline.read_text(encoding="utf-8"))
        if args.check_baseline_only and args.report_only:
            raise ValueError("--check-baseline-only and --report-only cannot be combined")
        if args.check_baseline_only:
            if args.previous_baseline is None:
                raise ValueError("--check-baseline-only requires --previous-baseline")
            previous = json.loads(args.previous_baseline.read_text(encoding="utf-8"))
            errors = check_baseline_transition(previous, policy)
            if errors:
                for error in errors:
                    print(f"coverage baseline error: {error}", file=sys.stderr)
                return 1
            print("coverage baseline only improves")
            return 0

        summary_text = args.summary.read_text(encoding="utf-8")
        root = Path(__file__).resolve().parents[1]
        source_files = tracked_source_files(root, policy.get("source_roots", []))
        if args.report_only:
            files, total = parse_summary(summary_text, root)
            files = add_unreported_sources(files, source_files)
            rows = [
                (path, row, "informational")
                for path, row in sorted(
                    files.items(), key=lambda item: (float(item[1]["coverage"]), item[0])
                )
            ]
            errors = []
        else:
            rows, errors, total = evaluate(
                summary_text,
                policy,
                args.platform,
                source_files,
                root,
            )
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"coverage policy error: {error}", file=sys.stderr)
        return 2

    report = markdown_table(rows, args.platform, total)
    profile = policy.get("platforms", {}).get(args.platform)
    if isinstance(profile, dict):
        try:
            total_floor = float(profile["total_floor"])
            measured_total = float(profile["measured_total"])
        except (KeyError, TypeError, ValueError):
            pass
        else:
            report = report.replace(
                f"Total: **{total:.2f}%**",
                f"Total: **{total:.2f}%** (floor {total_floor:.2f}%; "
                f"baseline {measured_total:.2f}%)",
            )
    print(report, end="")
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with Path(summary_path).open("a", encoding="utf-8") as summary_file:
            summary_file.write(report)

    if errors:
        for error in errors:
            print(f"coverage policy error: {error}", file=sys.stderr)
        return 1
    print(f"coverage policy passed for {args.platform}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
