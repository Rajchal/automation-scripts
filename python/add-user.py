#!/usr/bin/env python3
"""add-user.py

Create a system user (wrapper around `useradd`) with safe defaults.

This script is a minimal, non-destructive helper. By default it will print
the commands it would run. Use `--apply` to actually execute system changes.

Usage examples:
  python add-user.py alice --shell /bin/bash --sudo --apply
  python add-user.py bob --groups dev,git --password secret123 --apply
"""
from __future__ import annotations
import argparse
import random
import secrets
import shlex
import string
import subprocess
import sys


def run(cmd: list[str], dry_run: bool) -> int:
    print("+ "+shlex.join(cmd))
    if dry_run:
        return 0
    p = subprocess.run(cmd)
    return p.returncode


def generate_password(length: int = 16) -> str:
    alphabet = string.ascii_letters + string.digits
    return ''.join(secrets.choice(alphabet) for _ in range(length))


def main() -> int:
    parser = argparse.ArgumentParser(description="Create a system user safely")
    parser.add_argument("username", help="Username to create")
    parser.add_argument("--shell", default="/bin/bash", help="Login shell")
    parser.add_argument("--groups", help="Comma-separated supplementary groups")
    parser.add_argument("--password", help="Set initial password (insecure on CLI)")
    parser.add_argument("--random-password", action="store_true", help="Generate a random password and print it")
    parser.add_argument("--sudo", action="store_true", help="Add user to sudoers (via group 'sudo')")
    parser.add_argument("--no-create-home", action="store_true", help="Do not create home directory")
    parser.add_argument("--apply", action="store_true", help="Actually apply changes (default is dry-run)")
    args = parser.parse_args()

    dry_run = not args.apply
    username = args.username

    cmd = ["useradd", "-m" if not args.no_create_home else "-M", "-s", args.shell, username]
    # If groups provided
    if args.groups:
        cmd.extend(["-G", args.groups])
    # If sudo requested, add to sudo group
    if args.sudo:
        if args.groups:
            cmd[-1] = args.groups + ",sudo"
        else:
            cmd.extend(["-G", "sudo"]) if "-G" not in cmd else None

    # Normalize cmd: remove possible duplicates like '-G' without value
    cleaned_cmd: list[str] = []
    skip_next = False
    for i, part in enumerate(cmd):
        if skip_next:
            skip_next = False
            continue
        if part == "-G" and i + 1 < len(cmd) and cmd[i + 1] == "":
            skip_next = True
            continue
        cleaned_cmd.append(part)

    ret = run(cleaned_cmd, dry_run)
    if ret != 0:
        print("useradd failed", file=sys.stderr)
        return ret

    # Handle password
    password_used = None
    if args.random_password:
        password_used = generate_password()
    elif args.password:
        password_used = args.password

    if password_used:
        chpasswd = f"{username}:{password_used}"
        print("+ chpasswd (hidden) => <masked>")
        if not dry_run:
            p = subprocess.run(["chpasswd"], input=chpasswd, text=True)
            if p.returncode != 0:
                print("chpasswd failed", file=sys.stderr)
                return p.returncode

    if args.apply and args.sudo:
        # Ensure sudo group exists and user is in it (useradd handled group membership)
        pass

    if args.random_password and password_used:
        print(f"Generated password for {username}: {password_used}")

    print("Done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
