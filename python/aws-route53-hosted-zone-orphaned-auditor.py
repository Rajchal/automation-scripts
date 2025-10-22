#!/usr/bin/env python3
"""
aws-route53-hosted-zone-orphaned-auditor.py

Purpose:
  Find Route53 hosted zones that look orphaned:
    - Public or private hosted zones that contain only the default SOA/NS records (no useful records)
    - Private hosted zones with no VPC associations

Features:
  - Scans all hosted zones across accounts/regions (Route53 is global)
  - Filters: --name-filter, --private-only, --public-only
  - Optional tagging of hosted zones (dry-run by default) via --apply-tag
  - JSON or human readable output

Safety:
  - This tool is read-only by default. It does not delete zones.

Permissions:
  - route53:ListHostedZones, route53:GetHostedZone, route53:ListResourceRecordSets, route53:ListTagsForResource, route53:ChangeTagsForResource

Examples:
  python aws-route53-hosted-zone-orphaned-auditor.py --json
  python aws-route53-hosted-zone-orphaned-auditor.py --private-only --apply-tag --max-apply 10

Exit Codes:
  0 success
  1 unexpected error
"""
import argparse
import boto3
import json
import sys
from typing import Any, Dict, List, Optional


DEFAULT_EXCLUDE_TYPES = {"SOA", "NS"}


def parse_args():
    p = argparse.ArgumentParser(description="Audit Route53 hosted zones for orphaned zones or missing VPC associations")
    p.add_argument("--name-filter", help="Substring filter on hosted zone name")
    p.add_argument("--private-only", action="store_true", help="Only consider private hosted zones")
    p.add_argument("--public-only", action="store_true", help="Only consider public hosted zones")
    p.add_argument("--apply-tag", action="store_true", help="Apply tag to flagged hosted zones")
    p.add_argument("--tag-key", default="Cost:Review", help="Tag key (default: Cost:Review)")
    p.add_argument("--tag-value", default="route53-orphaned", help="Tag value (default: route53-orphaned)")
    p.add_argument("--max-apply", type=int, default=50, help="Max zones to tag (default: 50)")
    p.add_argument("--json", action="store_true", help="JSON output")
    return p.parse_args()


def list_hosted_zones(r53):
    out: List[Dict[str, Any]] = []
    token = None
    while True:
        kwargs = {}
        if token:
            kwargs["Marker"] = token
        resp = r53.list_hosted_zones(**kwargs)
        out.extend(resp.get("HostedZones", []))
        token = resp.get("NextMarker")
        if not token:
            break
    return out


def list_rrsets(r53, zone_id: str) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    token = None
    marker = None
    while True:
        kwargs: Dict[str, Any] = {"HostedZoneId": zone_id}
        if marker:
            kwargs["StartRecordName"] = marker
        resp = r53.list_resource_record_sets(**kwargs)
        out.extend(resp.get("ResourceRecordSets", []))
        if not resp.get("IsTruncated"):
            break
        marker = resp.get("NextRecordName")
    return out


def get_zone_tags(r53, zone_id: str) -> Dict[str, str]:
    try:
        arn = f"arn:aws:route53:::{zone_id}"
        resp = r53.list_tags_for_resource(ResourceType="hostedzone", ResourceId=zone_id)
        return {t.get("Key"): t.get("Value") for t in resp.get("ResourceTagSet", {}).get("Tags", [])}
    except Exception:
        return {}


def apply_tag(r53, zone_id: str, key: str, value: str) -> Optional[str]:
    try:
        # ChangeTagsForResource requires Tags list
        r53.change_tags_for_resource(ResourceType="hostedzone", ResourceId=zone_id, AddTags=[{"Key": key, "Value": value}])
        return None
    except Exception as e:
        return str(e)


def normalize_zone_id(zone_id: str) -> str:
    # HostedZoneId comes like "/hostedzone/Z1PA6795UKMFR9" from some APIs; strip prefix
    return zone_id.rsplit('/', 1)[-1]


def main():
    args = parse_args()
    r53 = boto3.client("route53")

    zones = list_hosted_zones(r53)
    results = []
    applied = 0

    for z in zones:
        zone_id_raw = z.get("Id")
        zone_id = normalize_zone_id(zone_id_raw)
        name = z.get("Name")
        private = bool(z.get("Config", {}).get("PrivateZone"))

        if args.name_filter and args.name_filter not in name:
            continue
        if args.private_only and not private:
            continue
        if args.public_only and private:
            continue

        # Get hosted zone details to inspect VPCs
        try:
            hz = r53.get_hosted_zone(Id=zone_id)
            vpcs = hz.get("VPCs", [])
        except Exception:
            vpcs = []

        # Resource record sets
        rrsets = list_rrsets(r53, zone_id)
        # Count records excluding SOA/NS
        useful_records = [r for r in rrsets if r.get("Type") not in DEFAULT_EXCLUDE_TYPES]

        no_useful_records = len(useful_records) == 0
        no_vpcs = private and len(vpcs) == 0

        flagged_reasons = []
        if no_useful_records:
            flagged_reasons.append("only SOA/NS or empty")
        if no_vpcs:
            flagged_reasons.append("private zone with no VPC association")

        if not flagged_reasons:
            continue

        tags = get_zone_tags(r53, zone_id)
        rec = {
            "zone_id": zone_id,
            "name": name,
            "private": private,
            "vpcs": vpcs,
            "useful_record_count": len(useful_records),
            "reasons": flagged_reasons,
            "tag_attempted": False,
            "tag_error": None,
        }

        if args.apply_tag and applied < args.max_apply:
            err = apply_tag(r53, zone_id, args.tag_key, args.tag_value)
            rec["tag_attempted"] = True
            rec["tag_error"] = err
            if err is None:
                applied += 1

        results.append(rec)

    payload = {
        "zones_scanned": len(zones),
        "apply_tag": args.apply_tag,
        "applied": applied,
        "results": results,
    }

    if args.json:
        print(json.dumps(payload, indent=2))
        return 0

    if not results:
        print("No orphaned hosted zones found under current filters.")
        return 0

    header = ["ZoneId", "Name", "Private", "UsefulRecords", "Reasons", "Tagged"]
    rows = [header]
    for r in results:
        rows.append([
            r["zone_id"], r["name"], "Y" if r["private"] else "N",
            r["useful_record_count"], ",".join(r["reasons"]),
            ("Y" if r["tag_attempted"] and not r["tag_error"] else ("ERR" if r["tag_error"] else "N")),
        ])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = '  '.join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print('  '.join('-' * w for w in widths))
        else:
            print(line)

    if not args.apply_tag:
        print("\nDry-run. Use --apply-tag to mark candidates for review.")
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('Interrupted', file=sys.stderr)
        sys.exit(130)
    except Exception as e:
        print(f'ERROR: {e}', file=sys.stderr)
        sys.exit(1)
