#!/usr/bin/env python3
"""
auto-update-delopy.py

Replicates the bash helper that pulls the latest code for a local repo and restarts a service.
Defaults mirror the original script: repo /var/www/myapp, remote origin, branch main, service nginx.
"""
import argparse
import subprocess
import sys
from pathlib import Path


def run(cmd, cwd=None) -> int:
    """Run command and stream output; return exit code."""
    proc = subprocess.run(cmd, cwd=cwd)
    return proc.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description="Pull latest code and restart a service")
    parser.add_argument("--repo", default="/var/www/myapp", help="Path to repo (default: /var/www/myapp)")
    parser.add_argument("--remote", default="origin", help="Git remote name (default: origin)")
    parser.add_argument("--branch", default="main", help="Branch to pull (default: main)")
    parser.add_argument("--service", default="nginx", help="Service to restart (default: nginx)")
    parser.add_argument("--skip-restart", action="store_true", help="Skip service restart step")
    args = parser.parse_args()

    repo_path = Path(args.repo)
    if not repo_path.exists():
        print(f"Repo path not found: {repo_path}", file=sys.stderr)
        return 2

    print(f"Pulling latest code in {repo_path}...")
    code = run(["git", "pull", args.remote, args.branch], cwd=repo_path)
    if code != 0:
        print("git pull failed", file=sys.stderr)
        return code

    if args.skip_restart:
        print("Skipping service restart as requested.")
        return 0

    print(f"Restarting service: {args.service}...")
    code = run(["systemctl", "restart", args.service])
    if code != 0:
        print("Service restart failed", file=sys.stderr)
        return code

    print("Deployment completed!")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
