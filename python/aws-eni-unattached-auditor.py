#!/usr/bin/env python3
"""
aws-eni-unattached-auditor.py

Purpose:
  Find unattached (status=available) Elastic Network Interfaces (ENIs) across
  regions so you can clean up stragglers left by manual operations or failed
  deployments. Supports dry-run reporting, filters, and optional deletion.

Features:
  - Multi-region scan
  - Filters:
      * --older-than-days N (based on CreateTime)
      * --required-tag Key=Value (repeatable)
      * --include-type TYPE (repeatable; e.g., interface, efa, trunk; default: all)
      * --name-filter substring on Description
  - Optional --delete to remove flagged ENIs (dry-run default)
  - Limits operations with --max-delete
  - JSON or human-readable output

Safety:
  - Only ENIs in status=available are considered for deletion
  - No changes unless --delete provided

Permissions:
  - ec2:DescribeNetworkInterfaces, ec2:DeleteNetworkInterface, ec2:DescribeRegions

Examples:
  python aws-eni-unattached-auditor.py --regions us-east-1 us-west-2 --older-than-days 2
  python aws-eni-unattached-auditor.py --required-tag Owner=dev --include-type interface --json
  python aws-eni-unattached-auditor.py --delete --max-delete 20

Exit Codes:
  0 success
  1 unexpected error
"""
import argparse
import boto3
import datetime as dt
import json
import sys
from typing import List, Dict, Any, Optional


def parse_args():
    p = argparse.ArgumentParser(description="Audit unattached ENIs (dry-run by default)")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all enabled)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--older-than-days", type=int, help="Only include ENIs older than this many days")
    p.add_argument("--required-tag", action="append", help="Limit to ENIs with Tag Key=Value (repeat)")
    p.add_argument("--include-type", action="append", help="InterfaceType to include (repeat; default: all)")
    p.add_argument("--name-filter", help="Substring filter on Description")
    p.add_argument("--delete", action="store_true", help="Delete flagged ENIs")
    p.add_argument("--max-delete", type=int, default=100, help="Max ENIs to delete")
    p.add_argument("--json", action="store_true", help="JSON output")
    return p.parse_args()


def session(profile: Optional[str]):
    if profile:
        return boto3.Session(profile_name=profile)
    return boto3.Session()


def discover_regions(sess, explicit):
    if explicit:
        return explicit
    try:
        ec2 = sess.client("ec2")
        resp = ec2.describe_regions(AllRegions=False)
        return sorted(r["RegionName"] for r in resp["Regions"])
    except Exception:
        return ["us-east-1"]


def parse_tag_filters(required: Optional[List[str]]):
    out = {}
    if not required:
        return out
    for r in required:
        if "=" not in r:
            continue
        k, v = r.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def tags_dict(tags_list: List[Dict[str, str]]):
    return {t.get('Key'): t.get('Value') for t in (tags_list or [])}


def matches_required(eni: Dict[str, Any], needed: Dict[str, str]) -> bool:
    if not needed:
        return True
    # NetworkInterface shapes commonly use 'TagSet'; some environments expose 'Tags'. Handle both.
    tag_list = eni.get('TagSet') or eni.get('Tags') or []
    t = tags_dict(tag_list)
    for k, v in needed.items():
        if t.get(k) != v:
            return False
    return True


def list_available_enis(ec2):
    out = []
    token = None
    while True:
        kwargs = {"MaxResults": 1000, "Filters": [
            {"Name": "status", "Values": ["available"]}
        ]}
        if token:
            kwargs["NextToken"] = token
        resp = ec2.describe_network_interfaces(**kwargs)
        out.extend(resp.get("NetworkInterfaces", []))
        token = resp.get("NextToken")
        if not token:
            break
    return out


def delete_eni(ec2, eni_id: str) -> Optional[str]:
    try:
        ec2.delete_network_interface(NetworkInterfaceId=eni_id)
        return None
    except Exception as e:
        return str(e)


def main():
    args = parse_args()
    sess = session(args.profile)
    regs = discover_regions(sess, args.regions)
    needed_tags = parse_tag_filters(args.required_tag)
    include_types = set([t.lower() for t in (args.include_type or [])])
    now = dt.datetime.utcnow()

    results = []
    deleted = 0

    for region in regs:
        ec2 = sess.client("ec2", region_name=region)
        try:
            enis = list_available_enis(ec2)
        except Exception as e:
            print(f"WARN region {region} list ENIs failed: {e}", file=sys.stderr)
            continue
        for eni in enis:
            eni_id = eni.get('NetworkInterfaceId')
            itype = (eni.get('InterfaceType') or '').lower()
            desc = eni.get('Description') or ''
            if args.name_filter and args.name_filter not in desc and args.name_filter not in eni_id:
                continue
            if include_types and itype not in include_types:
                continue
            if not matches_required(eni, needed_tags):
                continue
            create_time = eni.get('CreateTime')  # ENI shapes typically do not expose CreateTime; may remain None
            age_days = None
            if create_time:
                try:
                    if hasattr(create_time, 'tzinfo') and create_time.tzinfo:
                        create_time = create_time.astimezone(dt.timezone.utc).replace(tzinfo=None)
                    age_days = (now - create_time).days
                except Exception:
                    age_days = None
            # If an age filter is provided but age cannot be determined, skip conservatively.
            if args.older_than_days is not None:
                if age_days is None:
                    continue
                if age_days < args.older_than_days:
                    continue
            rec = {
                'region': region,
                'eni_id': eni_id,
                'interface_type': itype,
                'description': desc,
                'private_ip': eni.get('PrivateIpAddress'),
                'subnet_id': eni.get('SubnetId'),
                'vpc_id': eni.get('VpcId'),
                'security_groups': [g.get('GroupId') for g in eni.get('Groups', [])],
                'age_days': age_days,
                'delete_attempted': False,
                'delete_error': None,
            }
            if args.delete and deleted < args.max_delete:
                err = delete_eni(ec2, eni_id)
                rec['delete_attempted'] = True
                rec['delete_error'] = err
                if err is None:
                    deleted += 1
            results.append(rec)

    if args.json:
        print(json.dumps({
            'regions': regs,
            'older_than_days': args.older_than_days,
            'include_types': list(include_types) if include_types else None,
            'delete': args.delete,
            'deleted': deleted,
            'results': results,
        }, indent=2))
        return 0

    if not results:
        print("No unattached ENIs found under current filters.")
        return 0

    header = ["Region", "ENI", "Type", "Age(d)", "Subnet", "Deleted"]
    rows = [header]
    for r in results:
        rows.append([
            r['region'], r['eni_id'], r['interface_type'] or '-', r.get('age_days'), r.get('subnet_id'),
            'Y' if r['delete_attempted'] and not r['delete_error'] else ('ERR' if r['delete_error'] else 'N')
        ])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = '  '.join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print('  '.join('-' * w for w in widths))
        else:
            print(line)
    if not args.delete:
        print("\nDry-run only. Use --delete to remove flagged ENIs.")
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
