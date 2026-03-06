#!/usr/bin/env python3
"""
auto_swap_manager.py

Create and enable a swap file if no swap is currently active.
Defaults to a 2G swapfile at /swapfile; appends to /etc/fstab.
"""
import argparse
import subprocess
import sys
from pathlib import Path


def run(cmd):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def swap_active() -> bool:
    proc = run(["free"])
    if proc.returncode != 0:
        return False
    return "Swap" in proc.stdout and not any(line.startswith("Swap:") and line.split()[1] == "0" for line in proc.stdout.splitlines())


def create_swap(path: Path, size: str) -> int:
    print(f"Creating swap file {path} of size {size}...")
    for cmd in (
        ["fallocate", "-l", size, str(path)],
        ["chmod", "600", str(path)],
        ["mkswap", str(path)],
        ["swapon", str(path)],
    ):
        proc = run(cmd)
        sys.stdout.write(proc.stdout or "")
        if proc.returncode != 0:
            print(f"Command failed: {' '.join(cmd)}", file=sys.stderr)
            return proc.returncode
    return 0


def ensure_fstab(path: Path):
    entry = f"{path} none swap sw 0 0\n"
    fstab = Path("/etc/fstab")
    try:
        content = fstab.read_text()
    except Exception:
        content = ""
    if entry not in content:
        with fstab.open("a", encoding="utf-8") as fh:
            fh.write(entry)
        print("Added entry to /etc/fstab")
    else:
        print("/etc/fstab already contains swap entry")


def main() -> int:
    parser = argparse.ArgumentParser(description="Ensure swap exists; create if missing")
    parser.add_argument("--path", default="/swapfile", help="Swap file path (default: /swapfile)")
    parser.add_argument("--size", default="2G", help="Swap size (default: 2G)")
    args = parser.parse_args()

    swap_path = Path(args.path)

    if swap_active():
        print("Swap already exists.")
        return 0

    code = create_swap(swap_path, args.size)
    if code != 0:
        return code

    ensure_fstab(swap_path)
    print("Swap created and enabled.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
