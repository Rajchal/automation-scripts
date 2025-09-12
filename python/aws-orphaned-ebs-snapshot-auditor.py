#!/usr/bin/env python3
"""
aws-orphaned-ebs-snapshot-auditor.py

Purpose:
  Identify potentially orphaned or aged EBS snapshots to reclaim storage cost.
  An "orphaned" snapshot is one whose source VolumeId no longer exists in the
  region. Also flags snapshots older than a retention window (--days) even if
  the volume still exists (for review). Supports an optional deletion mode.

Features:
  - Multi-region scan
  - Detects snapshots referencing non-existent volumes
  - Age based flagging (older than --days)
  - Optional tag filter (--required-tag Key=Value) to only consider snapshots that match (can repeat)
  - Dry-run by default; --delete performs deletions
  - JSON output option
  - Rate limited via simple sleep if throttling encountered (basic backoff)

Safety:
  - Does not delete unless --delete specified
  - Deletion only applied to snapshots explicitly flagged ORPHAN or OLD

Permissions Required:
  - ec2:DescribeSnapshots, ec2:DescribeVolumes, ec2:DeleteSnapshot, ec2:DescribeRegions

Examples:
  python aws-orphaned-ebs-snapshot-auditor.py --regions us-east-1 us-west-2 --days 45
  python aws-orphaned-ebs-snapshot-auditor.py --profile prod --required-tag Backup=true --delete --json

Exit Codes:
  0 success (even if no snapshots)
  1 unexpected error
"""
import argparse
import boto3
import datetime as dt
import json
import sys
import time
from typing import List, Dict, Any, Optional, Tuple


def parse_args():
    p = argparse.ArgumentParser(description="Audit orphaned or aged EBS snapshots (dry-run)")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all enabled)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--days", type=int, default=90, help="Age threshold in days for OLD classification")
    p.add_argument("--required-tag", action="append", help="Key=Value tag filter to limit scope (can repeat)")
    p.add_argument("--owner-id", help="Restrict to snapshots owned by this AWS account ID (otherwise 'self')")
    p.add_argument("--delete", action="store_true", help="Actually delete flagged snapshots")
    p.add_argument("--max-delete", type=int, default=200, help="Maximum snapshots to delete in this run")
    p.add_argument("--json", action="store_true", help="JSON output")
    return p.parse_args()


def session(profile: Optional[str]):
    if profile:
        return boto3.Session(profile_name=profile)
    return boto3.Session()


def discover_regions(sess, explicit: Optional[List[str]]) -> List[str]:
    if explicit:
        return explicit
    try:
        ec2 = sess.client("ec2")
        resp = ec2.describe_regions(AllRegions=False)
        return sorted(r["RegionName"] for r in resp["Regions"])
    except Exception:
        return ["us-east-1"]


def parse_tag_filters(required_tags: Optional[List[str]]) -> Dict[str, str]:
    out = {}
    if not required_tags:
        return out
    for t in required_tags:
        if "=" not in t:
            continue
        k, v = t.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def snapshot_matches_tags(snap: Dict[str, Any], needed: Dict[str, str]) -> bool:
    if not needed:
        return True
    tags = {t['Key']: t['Value'] for t in snap.get('Tags', [])}
    for k, v in needed.items():
        if tags.get(k) != v:
            return False
    return True


def list_snapshots(ec2, owner_id: Optional[str]):
    owner = owner_id or 'self'
    token = None
    out = []
    while True:
        kwargs = {"OwnerIds": [owner], "MaxResults": 1000}
        if token:
            kwargs["NextToken"] = token
        resp = ec2.describe_snapshots(**kwargs)
        out.extend(resp.get("Snapshots", []))
        token = resp.get("NextToken")
        if not token:
            break
    return out


def list_volumes(ec2) -> set:
    token = None
    vols = set()
    while True:
        kwargs = {"MaxResults": 500}
        if token:
            kwargs["NextToken"] = token
        resp = ec2.describe_volumes(**kwargs)
        for v in resp.get("Volumes", []):
            vols.add(v.get("VolumeId"))
        token = resp.get("NextToken")
        if not token:
            break
    return vols


def classify_snapshot(snap: Dict[str, Any], existing_vols: set, cutoff: dt.datetime) -> Tuple[str, List[str]]:
    reasons = []
    vol_id = snap.get("VolumeId")
    start_time = snap.get("StartTime")
    if start_time and start_time.tzinfo:
        start_time = start_time.astimezone(dt.timezone.utc).replace(tzinfo=None)
    age_days = None
    if start_time:
        age_days = (dt.datetime.utcnow() - start_time).days
    status = "OK"
    if vol_id and vol_id not in existing_vols:
        status = "ORPHAN"
        reasons.append("Source volume missing")
    if start_time and start_time < cutoff:
        if status == "OK":
            status = "OLD"
        else:
            status = status + "+OLD"
        reasons.append(f"Older than cutoff ({age_days}d)")
    return status, reasons


def delete_snapshot(ec2, snapshot_id: str) -> Optional[str]:
    try:
        ec2.delete_snapshot(SnapshotId=snapshot_id)
        return None
    except Exception as e:
        return str(e)


def main():
    args = parse_args()
    sess = session(args.profile)
    regs = discover_regions(sess, args.regions)
    needed_tags = parse_tag_filters(args.required_tag)
    cutoff = dt.datetime.utcnow() - dt.timedelta(days=args.days)

    all_results = []
    delete_count = 0

    for region in regs:
        ec2 = sess.client("ec2", region_name=region)
        try:
            volumes = list_volumes(ec2)
        except Exception as e:
            print(f"WARN region {region} list volumes failed: {e}", file=sys.stderr)
            volumes = set()
        try:
            snaps = list_snapshots(ec2, args.owner_id)
        except Exception as e:
            print(f"WARN region {region} list snapshots failed: {e}", file=sys.stderr)
            continue
        for snap in snaps:
            if not snapshot_matches_tags(snap, needed_tags):
                continue
            sid = snap.get("SnapshotId")
            status, reasons = classify_snapshot(snap, volumes, cutoff)
            if status in ("OK",):
                continue
            entry = {
                "region": region,
                "snapshot_id": sid,
                "volume_id": snap.get("VolumeId"),
                "start_time": str(snap.get("StartTime")),
                "status": status,
                "reasons": reasons,
                "size_gb": snap.get("VolumeSize"),
                "encrypted": snap.get("Encrypted"),
                "tags": {t['Key']: t['Value'] for t in snap.get('Tags', [])},
                "delete_attempted": False,
                "delete_error": None,
            }
            if args.delete and delete_count < args.max_delete:
                err = delete_snapshot(ec2, sid)
                entry["delete_attempted"] = True
                entry["delete_error"] = err
                delete_count += 1
                if err:
                    # simple throttle/backoff on error that might be rate limit
                    time.sleep(1)
            all_results.append(entry)

    if args.json:
        print(json.dumps({
            "regions": regs,
            "cutoff_days": args.days,
            "delete": args.delete,
            "results": all_results,
        }, indent=2, default=str))
        return 0

    if not all_results:
        print("No orphaned or old snapshots found under current criteria.")
        return 0

    header = ["Region", "SnapshotId", "VolumeId", "Status", "Reasons", "SizeGB", "Deleted"]
    rows = [header]
    for r in all_results:
        rows.append([
            r["region"], r["snapshot_id"], r.get("volume_id"), r["status"], "; ".join(r["reasons"]), r.get("size_gb"),
            str(r["delete_attempted"]) + ("!" if r.get("delete_error") else "")
        ])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = "  ".join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print("  ".join("-" * w for w in widths))
        else:
            print(line)
    if not args.delete:
        print("\nDry-run only. Use --delete to actually remove snapshots.")
    print("Review deleted flag (!) indicates error if suffixed with '!'.")
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
