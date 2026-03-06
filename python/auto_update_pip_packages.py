#!/usr/bin/env python3
"""
auto_update_pip_packages.py

Update all outdated pip packages globally. Mirrors the bash one-liner.
"""
import subprocess
import sys


def main() -> int:
    # List outdated packages in freeze format, extract names, and upgrade one by one
    list_cmd = ["pip", "list", "--outdated", "--format=freeze"]
    proc = subprocess.run(list_cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    sys.stdout.write(proc.stdout or "")
    if proc.returncode != 0:
        print("Failed to list outdated packages", file=sys.stderr)
        return proc.returncode

    names = [line.split("==")[0] for line in proc.stdout.splitlines() if line.strip()]
    if not names:
        print("No outdated packages found")
        return 0

    for name in names:
        print(f"Upgrading {name}...")
        upgrade = subprocess.run(["pip", "install", "-U", name])
        if upgrade.returncode != 0:
            print(f"Failed to upgrade {name}", file=sys.stderr)
            return upgrade.returncode

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
