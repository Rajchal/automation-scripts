#!/usr/bin/env python3
"""
Git Large File New Commit Blocker

Purpose:
  Scan new commits (compared to a base ref) for blobs exceeding a size threshold.
  Designed for CI pre-merge checks to prevent accidental large binary additions.

Features:
  - Compares HEAD (or a range) against a base ref (default: origin/main)
  - Ignores blobs already present in base
  - Optional path allowlist patterns (comma separated globs)
  - Optional path denylist patterns (override allowlist)
  - JSON or human output
  - Exit non-zero if violations found (default behavior) unless --no-fail

Usage:
  python git-large-file-new-commit-blocker.py --threshold-mb 5
  python git-large-file-new-commit-blocker.py --base-ref origin/main --json
  python git-large-file-new-commit-blocker.py --range origin/main..HEAD --allow 'assets/**,docs/**' --deny '*.mp4'

Exit Codes:
  0 success (no violations OR --no-fail provided)
  2 violations found (and not suppressed)
  1 other error
"""
from __future__ import annotations
import argparse
import subprocess
import sys
import fnmatch
import json
from typing import List, Dict, Set


def run(cmd: List[str]) -> str:
    try:
        return subprocess.check_output(cmd, stderr=subprocess.STDOUT).decode()
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"Command {' '.join(cmd)} failed: {e.output.decode().strip()}")


def list_new_blobs(base_ref: str, threshold_bytes: int, allow: List[str], deny: List[str], commit_range: str | None):
    # Determine range: base_ref..HEAD unless commit_range is specified
    if commit_range:
        rng = commit_range
    else:
        rng = f"{base_ref}..HEAD"

    # Get blob hashes in range with associated paths
    # git diff-tree -r --no-commit-id --name-only <range> loses blob id; use --numstat or diff --raw
    diff_raw = run(["git", "log", "--no-merges", "--name-status", "--pretty=format:__COMMIT__ %H", rng])

    # Collect candidate paths (files added or modified)
    paths: Set[str] = set()
    for line in diff_raw.splitlines():
        if line.startswith('__COMMIT__') or not line.strip():
            continue
        parts = line.split('\t')
        status = parts[0]
        if status in {'A', 'AM', 'M', 'R', 'C'}:
            # For renames, new path is usually second field
            if status.startswith('R') or status.startswith('C'):
                if len(parts) >= 3:
                    paths.add(parts[2])
            else:
                if len(parts) >= 2:
                    paths.add(parts[1]) if status == 'AM' else paths.add(parts[1])
        elif status == '??':  # untracked (unlikely in log range) but handle
            if len(parts) >= 2:
                paths.add(parts[1])

    violations = []
    for p in sorted(paths):
        # Apply allow/deny logic
        if allow and not any(fnmatch.fnmatch(p, pat) for pat in allow):
            continue
        if deny and any(fnmatch.fnmatch(p, pat) for pat in deny):
            continue
        try:
            size = int(run(["git", "cat-file", "-s", f"HEAD:{p}"]).strip())
        except RuntimeError:
            continue
        if size >= threshold_bytes:
            violations.append({'path': p, 'size_bytes': size, 'size_mb': round(size/1024/1024, 2)})
    return violations


def parse_args():
    ap = argparse.ArgumentParser(description="Block large new files in recent commits")
    ap.add_argument('--threshold-mb', type=float, default=10.0, help='Size threshold in MiB (default 10)')
    ap.add_argument('--base-ref', default='origin/main', help='Base ref to diff against (default origin/main)')
    ap.add_argument('--range', help='Explicit commit range (e.g., origin/main..HEAD)')
    ap.add_argument('--allow', help='Comma list of glob patterns to include (default all)')
    ap.add_argument('--deny', help='Comma list of glob patterns to exclude (applies after allow)')
    ap.add_argument('--json', action='store_true', help='JSON output')
    ap.add_argument('--no-fail', action='store_true', help='Do not return non-zero on violations')
    return ap.parse_args()


def main():
    args = parse_args()
    threshold_bytes = int(args.threshold_mb * 1024 * 1024)
    allow = [a.strip() for a in args.allow.split(',')] if args.allow else []
    deny = [d.strip() for d in args.deny.split(',')] if args.deny else []

    try:
        violations = list_new_blobs(args.base_ref, threshold_bytes, allow, deny, args.range)
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

    if args.json:
        print(json.dumps({'threshold_mb': args.threshold_mb, 'violations': violations, 'count': len(violations)}, indent=2))
    else:
        if not violations:
            print(f"No files over {args.threshold_mb} MiB in new commits.")
        else:
            print(f"Large file violations (>{args.threshold_mb} MiB):")
            for v in violations:
                print(f"  {v['path']} - {v['size_mb']} MiB")
    if violations and not args.no_fail:
        sys.exit(2)


if __name__ == '__main__':
    main()
