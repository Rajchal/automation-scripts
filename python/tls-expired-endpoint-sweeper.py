#!/usr/bin/env python3
"""
tls-expired-endpoint-sweeper.py

Purpose:
  Concurrently scan a list of host:port endpoints for TLS certificate expiry,
  protocol versions, and chain validity issues to catch upcoming outages.

Features:
  - Input endpoints via --file (one host[:port] per line) or --endpoints args
  - Default port 443 if omitted
  - Concurrent scanning with --workers
  - Expiry threshold warning (--warn-days, default 30)
  - Optional JSON output with per-endpoint metadata
  - Basic chain validation via ssl.create_default_context() (hostname check)
  - Captures: notBefore, notAfter, subject CN, issuer, sans, days_remaining, negotiated protocol & cipher

Limitations:
  - Does not perform full CRL/OCSP revocation checks
  - SNI uses provided hostname

Exit Codes:
  0 success (even if findings) unless --fail-expiring is set and expiring endpoints found
  1 unexpected error
  2 expiring endpoints (when --fail-expiring)

Examples:
  python tls-expired-endpoint-sweeper.py --file endpoints.txt --json
  python tls-expired-endpoint-sweeper.py --endpoints example.com:8443 api.example.com --warn-days 15 --fail-expiring
"""
import argparse
import concurrent.futures as cf
import socket
import ssl
import sys
import json
import datetime as dt
from typing import List, Dict, Any, Tuple


def parse_args():
    p = argparse.ArgumentParser(description="Scan endpoints for TLS expiry and basic properties")
    p.add_argument("--file", help="File containing endpoints (host[:port])")
    p.add_argument("--endpoints", nargs="*", help="Endpoints list")
    p.add_argument("--workers", type=int, default=20, help="Concurrency level")
    p.add_argument("--timeout", type=float, default=6.0, help="Connection timeout seconds")
    p.add_argument("--warn-days", type=int, default=30, help="Warn if cert expires within this many days")
    p.add_argument("--json", action="store_true", help="JSON output")
    p.add_argument("--fail-expiring", action="store_true", help="Exit 2 if expiring endpoints detected")
    return p.parse_args()


def load_endpoints(args) -> List[str]:
    eps = []
    if args.file:
        try:
            with open(args.file, 'r', encoding='utf-8') as fh:
                for line in fh:
                    line = line.strip()
                    if not line or line.startswith('#'):
                        continue
                    eps.append(line)
        except FileNotFoundError:
            print(f"ERROR file not found: {args.file}", file=sys.stderr)
    if args.endpoints:
        eps.extend(args.endpoints)
    # de-dup preserve order
    seen = set()
    uniq = []
    for e in eps:
        if e not in seen:
            seen.add(e)
            uniq.append(e)
    return uniq


def parse_hostport(ep: str) -> Tuple[str, int]:
    if ':' in ep and ep.count(':') == 1:
        host, port = ep.split(':', 1)
        try:
            return host, int(port)
        except ValueError:
            return host, 443
    return ep, 443


def fetch_cert(host: str, port: int, timeout: float):
    ctx = ssl.create_default_context()
    try:
        with socket.create_connection((host, port), timeout=timeout) as sock:
            with ctx.wrap_socket(sock, server_hostname=host) as ssock:
                cert = ssock.getpeercert()
                proto = ssock.version()
                cipher = ssock.cipher()
                return cert, proto, cipher
    except Exception as e:
        raise RuntimeError(str(e))


def parse_dates(cert: Dict[str, Any]):
    # cert times are in ASN.1 format e.g. 'Jun  1 12:00:00 2025 GMT'
    def parse(t):
        return dt.datetime.strptime(t, '%b %d %H:%M:%S %Y GMT')
    not_before = parse(cert['notBefore'])
    not_after = parse(cert['notAfter'])
    return not_before, not_after


def extract_subject(cert):
    # subject is list of tuples of tuples
    cn = None
    for rdn in cert.get('subject', []):
        for (k, v) in rdn:
            if k == 'commonName':
                cn = v
    return cn


def extract_issuer(cert):
    parts = []
    for rdn in cert.get('issuer', []):
        for (k, v) in rdn:
            parts.append(f"{k}={v}")
    return ','.join(parts)


def extract_sans(cert):
    sans = []
    for ext in cert.get('subjectAltName', []):
        if ext[0] == 'DNS':
            sans.append(ext[1])
    return sans


def scan_endpoint(ep: str, args, now: dt.datetime):
    host, port = parse_hostport(ep)
    try:
        cert, proto, cipher = fetch_cert(host, port, args.timeout)
        nb, na = parse_dates(cert)
        days_left = (na - now).days + (na - now).seconds/86400.0
        status = 'OK'
        if days_left <= args.warn_days:
            status = 'EXPIRING'
        cn = extract_subject(cert)
        issuer = extract_issuer(cert)
        sans = extract_sans(cert)
        return {
            'endpoint': ep,
            'host': host,
            'port': port,
            'status': status,
            'days_remaining': days_left,
            'not_before': nb.isoformat(),
            'not_after': na.isoformat(),
            'common_name': cn,
            'issuer': issuer,
            'sans': sans,
            'protocol': proto,
            'cipher': cipher[0] if cipher else None,
            'cipher_details': cipher,
            'error': None,
        }
    except Exception as e:
        return {
            'endpoint': ep,
            'host': host,
            'port': port,
            'status': 'ERROR',
            'error': str(e),
        }


def main():
    args = parse_args()
    endpoints = load_endpoints(args)
    if not endpoints:
        print("No endpoints provided.", file=sys.stderr)
        return 1
    now = dt.datetime.utcnow()

    results = []
    with cf.ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(scan_endpoint, ep, args, now): ep for ep in endpoints}
        for fut in cf.as_completed(futs):
            results.append(fut.result())

    expiring = [r for r in results if r.get('status') == 'EXPIRING']

    if args.json:
        print(json.dumps({
            'warn_days': args.warn_days,
            'scanned': len(results),
            'expiring_count': len(expiring),
            'results': results,
        }, indent=2))
        if args.fail_expiring and expiring:
            return 2
        return 0

    # Human output
    rows = [["Endpoint", "Status", "DaysLeft", "NotAfter", "CN", "Issuer"]]
    for r in results:
        if r['status'] == 'ERROR':
            rows.append([r['endpoint'], 'ERROR', '-', '-', '-', r['error'][:60]])
        else:
            rows.append([
                r['endpoint'], r['status'], f"{r['days_remaining']:.1f}", r.get('not_after', '-')[:19],
                (r.get('common_name') or '-')[:30], (r.get('issuer') or '-')[:50]
            ])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(rows[0]))]
    for i, row in enumerate(rows):
        line = "  ".join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print("  ".join("-" * w for w in widths))
        else:
            print(line)
    if expiring:
        print(f"\nExpiring endpoints (<= {args.warn_days} days): {len(expiring)}")
    if args.fail_expiring and expiring:
        print("Failing due to expiring endpoints.")
        return 2
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
