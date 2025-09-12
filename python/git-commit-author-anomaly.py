#!/usr/bin/env python3
"""
git-commit-author-anomaly.py

Purpose:
  Detect commits introducing authors or emails not present in an allowlist,
  useful for supply chain hardening or accidental misconfigured Git identities.

Features:
  - Allows specifying a commit range (e.g. origin/main..HEAD)
  - Provide allowlist files or inline values for accepted author names/emails
  - JSON output option for CI integration
  - Exit with code 2 if anomalies detected

Allowlist precedence:
  1. --allow-author / --allow-email flags (can repeat)
  2. --allow-file (each line: author or email; blank/comments ignored)

Examples:
  python git-commit-author-anomaly.py --range origin/main..HEAD --allow-file .ci/allowed_authors.txt
  python git-commit-author-anomaly.py --range abc123..def456 --allow-email dev@example.com --json

Exit Codes:
  0 success, no anomalies
  1 unexpected error
  2 anomalies detected
"""
import argparse
import json
import os
import subprocess
import sys
from typing import List, Set, Dict, Any


def parse_args():
    p = argparse.ArgumentParser(description="Detect anomalous commit authors/emails")
    p.add_argument("--range", default="HEAD~50..HEAD", help="Commit range to scan (git log range syntax)")
    p.add_argument("--allow-author", action="append", help="Allowed author name (can repeat)")
    p.add_argument("--allow-email", action="append", help="Allowed author email (can repeat)")
    p.add_argument("--allow-file", action="append", help="File(s) containing allowed authors/emails one per line")
    p.add_argument("--repo", default=".", help="Repository path")
    p.add_argument("--json", action="store_true", help="JSON output")
    return p.parse_args()


def load_allowlist(args) -> Dict[str, Set[str]]:
    names: Set[str] = set()
    emails: Set[str] = set()
    if args.allow_author:
        names.update(a.strip() for a in args.allow_author if a.strip())
    if args.allow_email:
        emails.update(e.strip().lower() for e in args.allow_email if e.strip())
    files = args.allow_file or []
    for f in files:
        try:
            with open(f, 'r', encoding='utf-8') as fh:
                for line in fh:
                    line = line.strip()
                    if not line or line.startswith('#'):
                        continue
                    if '@' in line:
                        emails.add(line.lower())
                    else:
                        names.add(line)
        except FileNotFoundError:
            print(f"WARN allowlist file not found: {f}", file=sys.stderr)
    return {"names": names, "emails": emails}


def git_log(repo: str, commit_range: str) -> List[Dict[str, str]]:
    cmd = ["git", "-C", repo, "log", "--format=%H%x1f%an%x1f%ae", commit_range]
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True)
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"git log failed: {e.output.strip()}")
    commits = []
    for line in out.strip().splitlines():
        if not line:
            continue
        parts = line.split("\x1f")
        if len(parts) != 3:
            continue
        sha, name, email = parts
        commits.append({"sha": sha, "name": name, "email": email.lower()})
    return commits


def detect_anomalies(commits: List[Dict[str, str]], allow: Dict[str, Set[str]]):
    anomalies = []
    for c in commits:
        name_ok = c['name'] in allow['names'] if allow['names'] else True
        email_ok = c['email'] in allow['emails'] if allow['emails'] else True
        if not (name_ok and email_ok):
            anomalies.append(c)
    return anomalies


def main():
    args = parse_args()
    allow = load_allowlist(args)
    try:
        commits = git_log(args.repo, args.range)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1

    anomalies = detect_anomalies(commits, allow)

    if args.json:
        print(json.dumps({
            "range": args.range,
            "allow_names": sorted(list(allow['names'])),
            "allow_emails": sorted(list(allow['emails'])),
            "total_commits": len(commits),
            "anomalies": anomalies,
        }, indent=2))
        return 2 if anomalies else 0

    if not anomalies:
        print("No anomalous commit authors detected.")
        return 0

    print("Anomalous commit authors detected:")
    for a in anomalies:
        print(f"  {a['sha'][:10]}  {a['name']} <{a['email']}>")
    print("\nSuggested actions: verify commits, update allowlist if legitimate, or rebase/amend incorrect identities.")
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("Interrupted", file=sys.stderr)
        sys.exit(130)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
