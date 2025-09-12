#!/usr/bin/env python3
"""
dockerfile-secret-arg-scanner.py

Purpose:
  Scan Dockerfiles (recursively) for potentially sensitive ARG or ENV declarations
  and suspicious inline patterns (tokens, keys, passwords) to catch mistakes
  before images are built and pushed.

Detections (heuristic):
  - ARG/ENV names containing keywords: password, secret, key, token, credential, aws_access_key_id, aws_secret_access_key
  - Inline values that look like: base64 JWT header.payload.signature, AWS access key (AKIA...), 40+ hex chars, SSH private key headers
  - COPY instructions referencing files with .pem, .key, id_rsa
  - Hard-coded secrets in RUN export FOO=... patterns

Outputs:
  - Human-readable table or JSON (--json)
  - Severity levels: HIGH (probable secret), MEDIUM (suspicious name), LOW (info)

Safe: Read-only; does not modify any files.

Examples:
  python dockerfile-secret-arg-scanner.py --path ./ --json
  python dockerfile-secret-arg-scanner.py --path ./services --ignore vendor,node_modules

Exit Codes:
  0 success
  1 unexpected error
  2 findings (when --fail-on-findings)
"""
import argparse
import json
import os
import re
import sys
from typing import List, Dict, Any, Optional

SUSPICIOUS_NAME_KEYWORDS = [
    "password", "passwd", "secret", "token", "apikey", "api_key", "key", "credential", "creds",
    "aws_access_key_id", "aws_secret_access_key", "private_key"
]

HIGH_VALUE_PATTERNS = [
    (re.compile(r"AKIA[0-9A-Z]{16}"), "AWS Access Key"),
    (re.compile(r"(?i)aws_secret_access_key\s*=\s*['\"]?[A-Za-z0-9/+=]{30,40}"), "AWS Secret Key Inline"),
    (re.compile(r"-----BEGIN (?:RSA|EC|DSA|OPENSSH) PRIVATE KEY----"), "Private Key Header"),
    (re.compile(r"[A-Fa-f0-9]{40,}"), "Long Hex String (40+)"),
    (re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"), "JWT Token"),
]

COPY_SECRET_EXT = (".pem", ".key", ".p12", ".pfx")

RUN_EXPORT_RE = re.compile(r"export\s+([A-Za-z_][A-Za-z0-9_]*)=([^\s;]+)")
ARG_ENV_RE = re.compile(r"^(ARG|ENV)\s+([^=\s]+)(?:=([^\s]+))?")
COPY_RE = re.compile(r"^COPY\s+(.+)$")


def parse_args():
    p = argparse.ArgumentParser(description="Scan Dockerfiles for potential secret leakage")
    p.add_argument("--path", default=".", help="Root path to scan")
    p.add_argument("--ignore", help="Comma-separated directory names to ignore (exact match)")
    p.add_argument("--fail-on-findings", action="store_true", help="Exit 2 if any findings")
    p.add_argument("--json", action="store_true", help="JSON output")
    return p.parse_args()


def should_ignore(path: str, ignore: List[str]) -> bool:
    parts = path.split(os.sep)
    return any(part in ignore for part in parts)


def find_dockerfiles(root: str, ignore: List[str]) -> List[str]:
    candidates = []
    for dirpath, dirnames, filenames in os.walk(root):
        # prune ignored
        dirnames[:] = [d for d in dirnames if d not in ignore]
        for f in filenames:
            if f == "Dockerfile" or f.startswith("Dockerfile."):
                candidates.append(os.path.join(dirpath, f))
    return candidates


def classify_name(name: str) -> Optional[str]:
    lname = name.lower()
    for kw in SUSPICIOUS_NAME_KEYWORDS:
        if kw in lname:
            return "MEDIUM"
    return None


def scan_file(path: str) -> List[Dict[str, Any]]:
    findings = []
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as fh:
            lines = fh.readlines()
    except Exception as e:
        findings.append({
            "file": path,
            "line": 0,
            "type": "ERROR",
            "severity": "LOW",
            "reason": f"Read error: {e}",
        })
        return findings

    for idx, raw in enumerate(lines, start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = ARG_ENV_RE.match(line)
        if m:
            kind, name, value = m.groups()
            name_sev = classify_name(name)
            if name_sev:
                findings.append({
                    "file": path, "line": idx, "type": kind, "target": name, "severity": name_sev,
                    "reason": f"Suspicious variable name '{name}'"
                })
            if value:
                for patt, label in HIGH_VALUE_PATTERNS:
                    if patt.search(value):
                        findings.append({
                            "file": path, "line": idx, "type": kind, "target": name, "severity": "HIGH",
                            "reason": f"Inline {label} value"
                        })
        # RUN export pattern
        if line.startswith("RUN ") and "export" in line:
            for em in RUN_EXPORT_RE.finditer(line):
                name, val = em.groups()
                name_sev = classify_name(name)
                if name_sev:
                    findings.append({
                        "file": path, "line": idx, "type": "RUN_EXPORT", "target": name, "severity": name_sev,
                        "reason": f"Suspicious export variable '{name}'"
                    })
                for patt, label in HIGH_VALUE_PATTERNS:
                    if patt.search(val):
                        findings.append({
                            "file": path, "line": idx, "type": "RUN_EXPORT", "target": name, "severity": "HIGH",
                            "reason": f"Inline {label} value"
                        })
        # COPY secrets
        if line.startswith("COPY "):
            # naive split on spaces ignoring final forms
            parts = line.split()
            try:
                sources = parts[1:-1]
            except Exception:
                sources = []
            for src in sources:
                if any(src.endswith(ext) for ext in COPY_SECRET_EXT) or os.path.basename(src) in ("id_rsa", "id_dsa", "id_ed25519"):
                    findings.append({
                        "file": path, "line": idx, "type": "COPY", "target": src, "severity": "HIGH",
                        "reason": "Copy of potential secret material"
                    })
        # Generic high value tokens in any line (avoid duplicates by simple previously added check?)
        for patt, label in HIGH_VALUE_PATTERNS:
            if patt.search(line):
                findings.append({
                    "file": path, "line": idx, "type": "GENERIC", "severity": "HIGH", "reason": f"Pattern: {label}"
                })

    return findings


def main():
    args = parse_args()
    ignore = [x.strip() for x in args.ignore.split(",")] if args.ignore else []
    dockerfiles = find_dockerfiles(args.path, ignore)

    all_findings = []
    for df in dockerfiles:
        all_findings.extend(scan_file(df))

    if args.json:
        print(json.dumps({"dockerfiles": dockerfiles, "findings": all_findings}, indent=2))
        if args.fail_on_findings and all_findings:
            sys.exit(2)
        return 0

    if not all_findings:
        print("No suspicious patterns found in Dockerfiles.")
        return 0

    header = ["File", "Line", "Type", "Severity", "Reason"]
    rows = [header]
    for f in all_findings:
        rows.append([f.get("file"), f.get("line"), f.get("type"), f.get("severity"), f.get("reason")])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = "  ".join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print("  ".join("-" * w for w in widths))
        else:
            print(line)
    if args.fail_on_findings:
        print("\nFindings detected; failing with exit code 2.")
        sys.exit(2)
    else:
        print("\nFindings detected; review and rotate secrets if necessary.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("Interrupted", file=sys.stderr)
        sys.exit(130)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
