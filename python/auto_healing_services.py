#!/usr/bin/env python3
"""auto_healing_services.py

Check systemd services and attempt to restart ones that are not active.

This script is a safe helper: it performs a dry-run by default and prints
the actions it would take. Use `--apply` to actually restart services.

Examples:
  python auto_healing_services.py --services nginx,redis --apply
  python auto_healing_services.py nginx.service redis.service
"""
from __future__ import annotations
import argparse
import shutil
import subprocess
import sys
from typing import Iterable


def systemctl_exists() -> bool:
    return shutil.which("systemctl") is not None


def is_active(service: str) -> bool:
    p = subprocess.run(["systemctl", "is-active", service], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return p.returncode == 0


def restart(service: str) -> int:
    return subprocess.run(["systemctl", "restart", service]).returncode


def status(service: str) -> str:
    p = subprocess.run(["systemctl", "status", service, "--no-pager"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return p.stdout or p.stderr


def normalize_services(items: Iterable[str]) -> list[str]:
    out: list[str] = []
    for it in items:
        for s in it.split(","):
            s = s.strip()
            if not s:
                continue
            out.append(s if s.endswith(".service") or "." in s else s + ".service")
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="Auto-heal systemd services")
    parser.add_argument("services", nargs="*", help="Services to check (comma-separated allowed)")
    parser.add_argument("--apply", action="store_true", help="Actually restart services (default: dry-run)")
    args = parser.parse_args()

    if not systemctl_exists():
        print("systemctl not found on PATH; cannot manage services", file=sys.stderr)
        return 2

    if not args.services:
        print("No services specified; nothing to do.")
        return 0

    services = normalize_services(args.services)
    if not services:
        print("No valid services parsed; exiting.")
        return 0

    for svc in services:
        active = is_active(svc)
        if active:
            print(f"OK: {svc} is active")
            continue

        print(f"NOT ACTIVE: {svc}")
        print(status(svc))
        if args.apply:
            print(f"Attempting restart: {svc}")
            rc = restart(svc)
            if rc == 0:
                print(f"Restarted {svc} successfully")
            else:
                print(f"Failed to restart {svc} (rc={rc})", file=sys.stderr)
        else:
            print(f"Dry-run: would restart {svc}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
