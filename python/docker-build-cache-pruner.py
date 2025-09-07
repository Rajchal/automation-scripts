#!/usr/bin/env python3
"""
Docker Build Cache Pruner

Safely inspects and (optionally) prunes BuildKit / classic Docker builder cache.

Features:
  * Lists cache usage via `docker system df --format json` (fallback to plain parse)
  * Supports buildx cache pruning (builder instances) and classic `docker builder prune`
  * Age threshold (--older-than) and unused-only mode
  * Dry-run by default; must pass --apply to actually prune
  * Optional JSON output

Requirements:
  * Docker CLI installed and current user able to run docker commands
  * For buildx pruning, buildx plugin available (usually bundled now)

Examples:
  python docker-build-cache-pruner.py
  python docker-build-cache-pruner.py --older-than 24h --apply
  python docker-build-cache-pruner.py --builders mybuilder --json --apply

Exit codes:
  0 success (even if nothing pruned)
  1 error invoking docker
"""
from __future__ import annotations
import argparse
import json
import subprocess
import sys
import re
import datetime as dt
from typing import List, Dict, Any

DURATION_PATTERN = re.compile(r"^(\d+)([smhdw])$")
UNIT_SECONDS = {"s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}


def parse_args():
    p = argparse.ArgumentParser(description="Inspect / prune Docker build cache")
    p.add_argument("--older-than", default="0h", help="Only prune cache entries older than duration (e.g. 6h, 2d). 0h = any age")
    p.add_argument("--apply", action="store_true", help="Actually perform pruning (default dry-run)")
    p.add_argument("--unused-only", action="store_true", help="Prune only dangling/unused build cache")
    p.add_argument("--builders", help="Comma list of buildx builder names to prune (default: current)" )
    p.add_argument("--json", action="store_true", help="Output JSON summary")
    return p.parse_args()


def parse_duration(spec: str) -> int:
    m = DURATION_PATTERN.match(spec.strip())
    if not m:
        raise ValueError(f"Invalid duration: {spec}")
    value, unit = m.groups()
    return int(value) * UNIT_SECONDS[unit]


def run(cmd: List[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def docker_system_df() -> Dict[str, Any]:
    # Try JSON format (Docker 25+)
    cp = run(["docker", "system", "df", "--format", "{{json .}}"])  # each line JSON object
    if cp.returncode != 0:
        raise RuntimeError(cp.stderr.strip() or "docker system df failed")
    lines = [l for l in cp.stdout.splitlines() if l.strip()]
    objs = []
    for l in lines:
        try:
            objs.append(json.loads(l))
        except json.JSONDecodeError:
            pass
    summary = {"raw": objs}
    return summary


def prune_classic(age_seconds: int, apply: bool, unused_only: bool) -> Dict[str, Any]:
    cmd = ["docker", "builder", "prune", "-f"]
    if unused_only:
        # default is dangling; include nothing extra here
        pass
    else:
        cmd.append("--all")
    if age_seconds > 0:
        cmd.extend(["--filter", f"until={age_seconds}s"])
    if not apply:
        cmd.append("--dry-run")
    cp = run(cmd)
    return {
        'command': ' '.join(cmd),
        'returncode': cp.returncode,
        'stdout': cp.stdout,
        'stderr': cp.stderr,
    }


def prune_buildx(builders: List[str], age_seconds: int, apply: bool, unused_only: bool) -> List[Dict[str, Any]]:
    results = []
    for b in builders:
        cmd = ["docker", "buildx", "prune", "-f", "--builder", b]
        if not unused_only:
            cmd.append("--all")
        if age_seconds > 0:
            cmd.extend(["--filter", f"until={age_seconds}s"])
        if not apply:
            cmd.append("--dry-run")
        cp = run(cmd)
        results.append({
            'builder': b,
            'command': ' '.join(cmd),
            'returncode': cp.returncode,
            'stdout': cp.stdout,
            'stderr': cp.stderr,
        })
    return results


def list_builders() -> List[str]:
    cp = run(["docker", "buildx", "ls"])
    if cp.returncode != 0:
        return []
    builders = []
    for line in cp.stdout.splitlines():
        if not line.strip() or line.startswith("NAME"):
            continue
        parts = line.split()
        builders.append(parts[0])
    return builders


def summarize_prune_output(text: str) -> Dict[str, Any]:
    # Heuristic to extract reclaimed space lines like: "Reclaimed space: 123.4MB"
    reclaimed = None
    for line in text.splitlines():
        if 'Reclaimed space' in line:
            reclaimed = line.split(':',1)[1].strip()
    return {'reclaimed': reclaimed}


def main():
    args = parse_args()
    try:
        age_seconds = parse_duration(args.older_than)
    except ValueError as e:
        print(f"Error: {e}")
        sys.exit(1)

    try:
        df_summary = docker_system_df()
    except Exception as e:
        print(f"Error querying docker system df: {e}")
        sys.exit(1)

    builders = [b.strip() for b in args.builders.split(',')] if args.builders else list_builders()[:1]

    classic_result = prune_classic(age_seconds, args.apply, args.unused_only)
    buildx_results = prune_buildx(builders, age_seconds, args.apply, args.unused_only) if builders else []

    classic_summary = summarize_prune_output(classic_result['stdout'])
    buildx_summaries = [summarize_prune_output(r['stdout']) for r in buildx_results]

    if args.json:
        print(json.dumps({
            'age_seconds': age_seconds,
            'docker_df': df_summary,
            'classic': classic_result,
            'classic_summary': classic_summary,
            'buildx': buildx_results,
            'buildx_summaries': buildx_summaries,
            'apply': args.apply,
        }, indent=2))
        return

    print("Docker Build Cache Pruner")
    print(f"Dry-run: {not args.apply} | Age >= {age_seconds}s | Unused-only: {args.unused_only}")
    print(f"Builders: {','.join(builders) if builders else 'none'}")
    reclaimed_classic = classic_summary.get('reclaimed')
    if reclaimed_classic:
        print(f"Classic builder reclaimed (est): {reclaimed_classic}")
    for b, summ in zip(buildx_results, buildx_summaries):
        rec = summ.get('reclaimed') or 'n/a'
        print(f"Buildx {b['builder']} reclaimed (est): {rec}")
    print("\nCommands executed:")
    print(classic_result['command'])
    for r in buildx_results:
        print(r['command'])
    if not args.apply:
        print("\n(Dry run only - pass --apply to prune)")


if __name__ == '__main__':
    main()
