#!/usr/bin/env python3
"""auto-rollback.py

Monitor deployment logs and perform a rollback action on failure, or
run an explicit rollback command. Dry-run by default; use `--apply` to
actually execute rollback commands.

This replaces the previous minimal script with a safer, configurable
implementation.
"""
from __future__ import annotations
import argparse
import logging
import os
import subprocess
import sys
import time
from typing import Optional


LOG = logging.getLogger(__name__)


def run_cmd(cmd: list[str], apply: bool) -> int:
    LOG.info("Planned command: %s", " ".join(cmd))
    if not apply:
        LOG.info("Dry-run: not executing")
        return 0
    try:
        p = subprocess.run(cmd)
        return p.returncode
    except FileNotFoundError:
        LOG.error("Command not found: %s", cmd[0])
        return 127


def monitor_log_file(path: str, trigger_text: str, rollback_cmd: Optional[list[str]], apply: bool, poll: float = 1.0) -> int:
    if not os.path.exists(path):
        LOG.error("Log file does not exist: %s", path)
        return 2

    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        fh.seek(0, os.SEEK_END)
        while True:
            line = fh.readline()
            if not line:
                time.sleep(poll)
                continue
            if trigger_text in line:
                LOG.warning("Trigger text detected in log: %s", trigger_text)
                if rollback_cmd:
                    return run_cmd(rollback_cmd, apply)
                else:
                    LOG.error("No rollback command provided; cannot perform rollback")
                    return 3


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s: %(message)s")
    parser = argparse.ArgumentParser(description="Auto rollback helper")
    parser.add_argument("--log-file", default=os.environ.get("DEPLOY_LOG", "/var/log/deploy.log"), help="Deployment log file to monitor")
    parser.add_argument("--trigger", default=os.environ.get("DEPLOY_FAILURE_TRIGGER", "deployment failed"), help="Text to watch for in logs that triggers rollback")
    parser.add_argument("--rollback-cmd", help="Rollback command to run (shell form). Example: '/usr/local/bin/rollback.sh arg'")
    parser.add_argument("--apply", action="store_true", help="Actually execute rollback command (default: dry-run)")
    parser.add_argument("--once", action="store_true", help="Exit after first match and (optionally) rollback")
    args = parser.parse_args()

    rollback_cmd = None
    if args.rollback_cmd:
        # simple split; if complex commands are needed user can pass a small wrapper script
        rollback_cmd = args.rollback_cmd.split()

    try:
        rc = monitor_log_file(args.log_file, args.trigger, rollback_cmd, args.apply)
        if args.once:
            return rc
        # otherwise continue running until interrupted
        return rc
    except KeyboardInterrupt:
        LOG.info("Interrupted by user")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
