#!/usr/bin/env python3
"""
aws-ebs-unattached-volume-auditor.py

Purpose:
  Find unattached (available) EBS volumes across regions so you can clean them
  up or snapshot before removal. Estimates simple monthly storage cost.

Heuristics:
  - Volume state == 'available' (no attachments)
  - Optional age filter: CreateTime older than --older-than-days

Features:
  - Multi-region scan
  - Tag filters (--required-tag Key=Value) repeatable
  - JSON or human-friendly table output
  - Optional deletion with --apply (dry-run default)
  - Optional --snapshot-before-delete to create a snapshot then delete
  - Cap operations with --max-apply

Cost Estimate:
  - Uses a flat rate of $0.10/GB-month (approx gp2/gp3 baseline)

Permissions:
  - ec2:DescribeVolumes, ec2:CreateSnapshot, ec2:DeleteVolume, ec2:DescribeRegions, ec2:CreateTags

Examples:
  python aws-ebs-unattached-volume-auditor.py --regions us-east-1 us-west-2 --older-than-days 7
  python aws-ebs-unattached-volume-auditor.py --required-tag Keep!=true --snapshot-before-delete --apply --json

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

GB_COST = 0.10


def parse_args():
    p = argparse.ArgumentParser(description="Audit unattached (available) EBS volumes; dry-run by default")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all enabled)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--older-than-days", type=int, help="Only include volumes older than this many days")
    p.add_argument("--required-tag", action="append", help="Limit to volumes with Tag Key=Value (repeat)")
    p.add_argument("--apply", action="store_true", help="Delete flagged volumes (dangerous)")
    p.add_argument("--snapshot-before-delete", action="store_true", help="Create snapshot before deletion")
    p.add_argument("--snapshot-tag", action="append", help="Tags to set on created snapshots Key=Value (repeat)")
    p.add_argument("--max-apply", type=int, default=100, help="Max volumes to operate on")
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


def parse_snapshot_tags(tags: Optional[List[str]]):
    items = []
    for t in tags or []:
        if "=" not in t:
            continue
        k, v = t.split("=", 1)
        items.append({"Key": k.strip(), "Value": v.strip()})
    return items


def tags_dict(tags_list: List[Dict[str, str]]):
    return {t.get('Key'): t.get('Value') for t in (tags_list or [])}


def matches_required(vol: Dict[str, Any], needed: Dict[str, str]):
    if not needed:
        return True
    t = tags_dict(vol.get('Tags', []))
    for k, v in needed.items():
        if t.get(k) != v:
            return False
    return True


def list_available_volumes(ec2):
    out = []
    token = None
    while True:
        kwargs = {"MaxResults": 500, "Filters": [
            {"Name": "status", "Values": ["available"]}
        ]}
        if token:
            kwargs["NextToken"] = token
        resp = ec2.describe_volumes(**kwargs)
        out.extend(resp.get("Volumes", []))
        token = resp.get("NextToken")
        if not token:
            break
    return out


def create_snapshot(ec2, volume_id: str, description: str, tags: List[Dict[str, str]]):
    try:
        resp = ec2.create_snapshot(VolumeId=volume_id, Description=description)
        snap_id = resp.get('SnapshotId')
        if tags:
            try:
                ec2.create_tags(Resources=[snap_id], Tags=tags)
            except Exception:
                pass
        return snap_id, None
    except Exception as e:
        return None, str(e)


def delete_volume(ec2, volume_id: str):
    try:
        ec2.delete_volume(VolumeId=volume_id)
        return None
    except Exception as e:
        return str(e)


def human_size_gb(gb: int) -> str:
    return f"{gb}GB"


def main():
    args = parse_args()
    sess = session(args.profile)
    regs = discover_regions(sess, args.regions)
    needed_tags = parse_tag_filters(args.required_tag)
    snap_tags = parse_snapshot_tags(args.snapshot_tag)
    now = dt.datetime.utcnow()

    results = []
    operated = 0

    for region in regs:
        ec2 = sess.client("ec2", region_name=region)
        try:
            vols = list_available_volumes(ec2)
        except Exception as e:
            print(f"WARN region {region} list volumes failed: {e}", file=sys.stderr)
            continue
        for v in vols:
            if not matches_required(v, needed_tags):
                continue
            created = v.get('CreateTime')
            age_days = None
            if created:
                if created.tzinfo:
                    created = created.astimezone(dt.timezone.utc).replace(tzinfo=None)
                age_days = (now - created).days
            if args.older_than_days is not None and age_days is not None and age_days < args.older_than_days:
                continue
            size = v.get('Size', 0)
            cost = round(size * GB_COST, 2)
            rec = {
                'region': region,
                'volume_id': v.get('VolumeId'),
                'size_gb': size,
                'type': v.get('VolumeType'),
                'iops': v.get('Iops'),
                'throughput': v.get('Throughput'),
                'age_days': age_days,
                'tags': tags_dict(v.get('Tags', [])),
                'estimated_monthly_cost_usd': cost,
                'snapshot_id': None,
                'snapshot_error': None,
                'delete_attempted': False,
                'delete_error': None,
            }
            if args.apply and operated < args.max_apply:
                snap_id = None
                if args.snapshot_before_delete:
                    desc = f"Pre-delete snapshot of {rec['volume_id']} via auditor"
                    snap_id, snap_err = create_snapshot(ec2, rec['volume_id'], desc, snap_tags)
                    rec['snapshot_id'] = snap_id
                    rec['snapshot_error'] = snap_err
                del_err = delete_volume(ec2, rec['volume_id'])
                rec['delete_attempted'] = True
                rec['delete_error'] = del_err
                operated += 1
            results.append(rec)

    if args.json:
        print(json.dumps({
            'regions': regs,
            'older_than_days': args.older_than_days,
            'apply': args.apply,
            'snapshot_before_delete': args.snapshot_before_delete,
            'max_apply': args.max_apply,
            'results': results,
        }, indent=2))
        return 0

    if not results:
        print("No unattached EBS volumes found under current filters.")
        return 0

    header = ["Region", "Volume", "Size", "Age(d)", "Cost", "Snap", "Deleted"]
    rows = [header]
    for r in results:
        rows.append([
            r['region'], r['volume_id'], human_size_gb(r['size_gb']), r.get('age_days'), f"${r['estimated_monthly_cost_usd']:.2f}",
            (r['snapshot_id'] or ("ERR" if r['snapshot_error'] else "-")),
            ("Y" if r['delete_attempted'] and not r['delete_error'] else ("ERR" if r['delete_error'] else "N"))
        ])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = "  ".join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print("  ".join("-" * w for w in widths))
        else:
            print(line)
    if not args.apply:
        print("\nDry-run only. Use --apply to delete flagged volumes. Add --snapshot-before-delete to create a snapshot first.")
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
