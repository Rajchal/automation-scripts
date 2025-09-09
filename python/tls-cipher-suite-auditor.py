#!/usr/bin/env python3
"""
TLS Cipher Suite Auditor

Scans a list of host:port endpoints (provided via --targets or file) and reports:
  * Supported protocol versions (SSLv3..TLSv1.3 subset attempted)
  * Accepted ciphers per protocol (via openssl s_client -cipher/-ciphersuites)
  * Flags weak / legacy ciphers (NULL, EXPORT, RC4, 3DES, MD5, aNULL, eNULL, DES, CBC under TLS1.0/1.1)
  * Certificate expiration summary (days remaining)

Modes:
  - Fast summary (default): only highest negotiated protocol + cipher, plus expiry
  - Deep scan (--full): enumerate cipher lists for TLSv1.0..TLSv1.3

Requires: OpenSSL CLI available in PATH.

Usage:
  python tls-cipher-suite-auditor.py --targets example.com:443,api.example.com:8443
  python tls-cipher-suite-auditor.py --file targets.txt --full --json

Exit codes:
  0 success
  1 error (missing openssl or execution failure)

Notes:
  - Full cipher enumeration can be slow; limit targets or run without --full first.
  - OpenSSL 1.1.x may differ in TLS1.3 handling vs 3.x.
"""
from __future__ import annotations
import argparse
import subprocess
import re
import json
import ssl
import socket
import datetime as dt
from typing import List, Dict, Any, Optional

WEAK_PATTERNS = [r"NULL", r"RC4", r"MD5", r"3DES", r"DES-", r"EXPORT", r"aNULL", r"eNULL", r"CBC"]
TLS_PROTOCOLS = ["TLSv1", "TLSv1_1", "TLSv1_2", "TLSv1_3"]  # ordering for full scan attempts


def parse_args():
    p = argparse.ArgumentParser(description="Audit TLS cipher/protocol support")
    p.add_argument('--targets', help='Comma list host:port entries')
    p.add_argument('--file', help='File with one host:port per line')
    p.add_argument('--timeout', type=float, default=5.0, help='Connection timeout seconds (default 5)')
    p.add_argument('--full', action='store_true', help='Enumerate ciphers per protocol')
    p.add_argument('--json', action='store_true', help='JSON output')
    p.add_argument('--include-cbc', action='store_true', help='Do not treat CBC as weak (some environments still allow)')
    return p.parse_args()


def load_targets(args) -> List[str]:
    targets = []
    if args.targets:
        targets.extend([t.strip() for t in args.targets.split(',') if t.strip()])
    if args.file:
        with open(args.file) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    targets.append(line)
    return sorted(set(targets))


def get_cert_expiry(host: str, port: int, timeout: float) -> Optional[int]:
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((host, port), timeout=timeout) as sock:
            with ctx.wrap_socket(sock, server_hostname=host) as ssock:
                cert = ssock.getpeercert()
                not_after = cert.get('notAfter')
                if not_after:
                    exp = dt.datetime.strptime(not_after, '%b %d %H:%M:%S %Y %Z')
                    return (exp - dt.datetime.utcnow()).days
    except Exception:
        return None
    return None


def run_openssl(host: str, port: int, extra: List[str], timeout: float) -> subprocess.CompletedProcess:
    cmd = ['openssl', 's_client', '-connect', f'{host}:{port}', '-servername', host] + extra
    try:
        cp = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as e:
        class Dummy:  # minimal object similar to CompletedProcess
            returncode = 124
            stdout = ''
            stderr = 'timeout'
        return Dummy()
    return cp


def negotiate_once(host: str, port: int, timeout: float):
    cp = run_openssl(host, port, ['-brief'], timeout)
    if cp.returncode != 0:
        return None
    proto = None
    cipher = None
    for line in cp.stdout.splitlines():
        if line.startswith('Protocol  :'):
            proto = line.split(':',1)[1].strip()
        if line.startswith('Cipher    :'):
            cipher = line.split(':',1)[1].strip()
    return {'protocol': proto, 'cipher': cipher}


def list_ciphers_for_protocol(host: str, port: int, proto: str, timeout: float) -> List[str]:
    # We attempt handshake with a set of cipher strings; easier approach: use openssl ciphers -v then test individually.
    # For brevity we attempt with -tls1 / -tls1_1 / -tls1_2; TLS1.3 ciphers are fixed but we list them via a handshake.
    flag = {
        'TLSv1': '-tls1',
        'TLSv1_1': '-tls1_1',
        'TLSv1_2': '-tls1_2',
        'TLSv1_3': '-tls1_3',
    }.get(proto)
    if not flag:
        return []
    # Use openssl ciphers output list and test each quickly.
    cp = subprocess.run(['openssl', 'ciphers', 'ALL:@SECLEVEL=0'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if cp.returncode != 0:
        return []
    all_ciphers = cp.stdout.strip().split(':')
    accepted = []
    for c in all_ciphers:
        test = run_openssl(host, port, [flag, '-cipher', c], timeout)
        if test.returncode == 0 and 'Cipher is (NONE)' not in test.stdout:
            # Confirm selected cipher appears in output lines
            if re.search(rf'Cipher    :\s*{re.escape(c)}', test.stdout):
                accepted.append(c)
        if len(accepted) >= 200:  # safety bound
            break
    return accepted


def classify_cipher(c: str, include_cbc: bool) -> List[str]:
    issues = []
    for pat in WEAK_PATTERNS:
        if pat == 'CBC' and include_cbc:
            continue
        if re.search(pat, c, re.IGNORECASE):
            issues.append(pat)
    return issues


def audit_target(target: str, full: bool, timeout: float, include_cbc: bool):
    host, _, port_s = target.partition(':')
    port = int(port_s or 443)
    negotiated = negotiate_once(host, port, timeout)
    expiry_days = get_cert_expiry(host, port, timeout)
    result = {
        'target': target,
        'reachable': negotiated is not None,
        'negotiated': negotiated,
        'expiry_days': expiry_days,
        'protocols': [],
        'weak_findings': [],
    }
    if not negotiated:
        return result
    if full:
        for proto in TLS_PROTOCOLS:
            ciphers = list_ciphers_for_protocol(host, port, proto, timeout)
            if not ciphers:
                continue
            proto_entry = {'protocol': proto, 'count': len(ciphers), 'ciphers': ciphers}
            result['protocols'].append(proto_entry)
            for c in ciphers:
                issues = classify_cipher(c, include_cbc)
                if issues:
                    result['weak_findings'].append({'protocol': proto, 'cipher': c, 'issues': issues})
    else:
        # Just classify the negotiated cipher
        if negotiated.get('cipher'):
            issues = classify_cipher(negotiated['cipher'], include_cbc)
            if issues:
                result['weak_findings'].append({'protocol': negotiated.get('protocol'), 'cipher': negotiated['cipher'], 'issues': issues})
    return result


def print_human(results):
    print("TLS Cipher Suite Audit Summary")
    for r in results:
        if not r['reachable']:
            print(f"{r['target']}: UNREACHABLE")
            continue
        neg = r['negotiated']
        exp = r['expiry_days']
        exp_txt = f"{exp}d" if exp is not None else 'unknown'
        weak_count = len(r['weak_findings'])
        print(f"{r['target']}: {neg.get('protocol')} {neg.get('cipher')} cert-expiry={exp_txt} weak={weak_count}")
        for wf in r['weak_findings'][:5]:  # show first few
            print(f"   - {wf['protocol']} {wf['cipher']} issues={','.join(wf['issues'])}")
        if weak_count > 5:
            print(f"   ... {weak_count-5} more weak ciphers")


def main():
    args = parse_args()
    targets = load_targets(args)
    if not targets:
        print('No targets specified')
        return
    try:
        results = [audit_target(t, args.full, args.timeout, args.include_cbc) for t in targets]
    except FileNotFoundError:
        print('Error: openssl not found in PATH')
        exit(1)

    if args.json:
        print(json.dumps({'results': results}, indent=2))
        return
    print_human(results)


if __name__ == '__main__':
    main()
