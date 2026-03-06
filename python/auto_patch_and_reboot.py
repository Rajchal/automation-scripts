#!/usr/bin/env python3
"""
auto_patch_and_reboot.py

Python equivalent of the bash helper: update packages, clean up, and reboot if required.
Defaults to apt-based systems and logs to /var/log/auto_patch_and_reboot.log.
"""
import argparse
import subprocess
import sys
from pathlib import Path
from datetime import datetime

LOG_PATH = Path("/var/log/auto_patch_and_reboot.log")


def run(cmd, log_file) -> int:
    """Run a command, stream output to stdout/stderr, and append to log."""
    with log_file.open("a", encoding="utf-8") as fh:
        fh.write(f"$ {' '.join(cmd)}\n")
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    with log_file.open("a", encoding="utf-8") as fh:
        fh.write(proc.stdout or "")
    sys.stdout.write(proc.stdout or "")
    return proc.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description="Auto patch and reboot if required (apt-based)")
    parser.add_argument("--log", default=str(LOG_PATH), help="Log file path (default: /var/log/auto_patch_and_reboot.log)")
    parser.add_argument("--no-reboot", action="store_true", help="Do not reboot even if required")
    args = parser.parse_args()

    log_file = Path(args.log)
    log_file.parent.mkdir(parents=True, exist_ok=True)

    header = f"=== System Patch and Reboot: {datetime.now()} ===\n"
    with log_file.open("a", encoding="utf-8") as fh:
        fh.write(header)
    print(header, end="")

    for step in [
        ("Updating package lists...", ["apt", "update"]),
        ("Upgrading packages...", ["apt", "-y", "upgrade"]),
        ("Cleaning up (autoremove)...", ["apt", "-y", "autoremove"]),
        ("Cleaning up (autoclean)...", ["apt", "-y", "autoclean"]),
    ]:
        print(step[0])
        code = run(step[1], log_file)
        if code != 0:
            print(f"Step failed: {step[0]}", file=sys.stderr)
            return code

    reboot_required = Path("/var/run/reboot-required").exists()
    print("Checking for reboot required...")
    with log_file.open("a", encoding="utf-8") as fh:
        fh.write("Checking for reboot required...\n")

    if reboot_required and not args.no_reboot:
        print("Reboot required. Rebooting now...")
        with log_file.open("a", encoding="utf-8") as fh:
            fh.write("Reboot required. Rebooting now...\n")
        subprocess.run(["shutdown", "-r", "now"])
    elif reboot_required:
        print("Reboot required but --no-reboot set. Skipping reboot.")
        with log_file.open("a", encoding="utf-8") as fh:
            fh.write("Reboot required but --no-reboot set. Skipping reboot.\n")
    else:
        print("No reboot required.")
        with log_file.open("a", encoding="utf-8") as fh:
            fh.write("No reboot required.\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
