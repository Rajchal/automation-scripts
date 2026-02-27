#!/usr/bin/env python3
"""auto_dns_update.py

Minimal automation to update DNS records. Currently supports AWS Route53.
Dry-run by default; pass `--apply` to perform changes.

Usage examples:
  python auto_dns_update.py --provider route53 --zone-id Z1234 --name example.foo. --type A --value 1.2.3.4
  python auto_dns_update.py --provider route53 --zone-id Z1234 --name example.foo. --type A --value 1.2.3.4 --apply
"""
from __future__ import annotations
import argparse
import json
import sys


def update_route53(zone_id: str, name: str, rtype: str, value: str, ttl: int, apply: bool) -> int:
    try:
        import boto3
        from botocore.exceptions import BotoCoreError, ClientError
    except Exception:
        print("boto3 is required for Route53 operations. Install it or run in dry-run.", file=sys.stderr)
        return 3

    client = boto3.client("route53")
    change = {
        "Comment": "auto_dns_update",
        "Changes": [
            {
                "Action": "UPSERT",
                "ResourceRecordSet": {
                    "Name": name,
                    "Type": rtype,
                    "TTL": ttl,
                    "ResourceRecords": [{"Value": value}],
                },
            }
        ],
    }

    print("Planned change:")
    print(json.dumps(change, indent=2))

    if not apply:
        print("Dry-run: no changes applied. Re-run with --apply to commit.")
        return 0

    try:
        resp = client.change_resource_record_sets(HostedZoneId=zone_id, ChangeBatch=change)
        print("Change submitted:", resp.get("ChangeInfo", {}).get("Id"))
        return 0
    except (BotoCoreError, ClientError) as e:
        print("Failed to submit change:", e, file=sys.stderr)
        return 4


def main() -> int:
    parser = argparse.ArgumentParser(description="Auto DNS update helper")
    parser.add_argument("--provider", choices=["route53"], default="route53")
    parser.add_argument("--zone-id", help="Route53 hosted zone id (e.g. Z1234)")
    parser.add_argument("--name", required=True, help="Record name (must end with a dot)")
    parser.add_argument("--type", default="A", help="Record type (A, CNAME, etc.)")
    parser.add_argument("--value", required=True, help="Record value (IP or target)")
    parser.add_argument("--ttl", type=int, default=300, help="TTL for the record")
    parser.add_argument("--apply", action="store_true", help="Apply the change (default: dry-run)")
    args = parser.parse_args()

    if args.provider == "route53":
        if not args.zone_id:
            print("--zone-id is required for route53", file=sys.stderr)
            return 2
        return update_route53(args.zone_id, args.name, args.type, args.value, args.ttl, args.apply)

    print("Unsupported provider", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
