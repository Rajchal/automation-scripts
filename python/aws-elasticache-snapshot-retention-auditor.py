#!/usr/bin/env python3
"""
aws-elasticache-snapshot-retention-auditor.py

Purpose:
  Audit ElastiCache (Redis) automatic snapshot retention and age of manual snapshots across regions.
  Flags replication groups with low RetentionLimit and manual snapshots older than --max-manual-age-days.
  Optionally tag replication groups / snapshots for review.

Features:
  - Multi-region scan (all enabled unless --regions provided)
  - Checks:
      * ReplicationGroup: Automatic snapshot retention (RetentionLimit) < --min-retention (default 7)
      * Manual Snapshot: Age in days > --max-manual-age-days (default 30)
  - Filters: --name-filter substring on ReplicationGroupId or snapshot name
  - Actions: --apply-tag (safe, metadata) with caps (--max-tag) for replication groups & snapshots separately
  - Output: human table or --json
  - CI integration: --ci-exit-on-findings returns exit code 2 if any findings

Safety:
  - No delete operations performed. Tagging only when requested.
  - Manual snapshot cleanup decisions remain manual.

Permissions:
  - elasticache:DescribeReplicationGroups, elasticache:DescribeSnapshots, elasticache:AddTagsToResource
  - ec2:DescribeRegions

Examples:
  python aws-elasticache-snapshot-retention-auditor.py --regions us-east-1 us-west-2 --json
  python aws-elasticache-snapshot-retention-auditor.py --min-retention 5 --max-manual-age-days 45 --apply-tag --max-tag 20

Exit Codes:
  0 success
  1 unexpected error
  2 findings (when --ci-exit-on-findings used)
"""
import argparse
import boto3
import datetime as dt
import json
import sys
from typing import Any, Dict, List, Optional


def parse_args():
    p = argparse.ArgumentParser(description="Audit ElastiCache snapshot retention and manual snapshot age (dry-run by default)")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all enabled)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--min-retention", type=int, default=7, help="Minimum RetentionLimit days for automatic snapshots (default: 7)")
    p.add_argument("--max-manual-age-days", type=int, default=30, help="Max age for manual snapshots before flagging (default: 30)")
    p.add_argument("--name-filter", help="Substring filter on ReplicationGroupId or snapshot name")
    p.add_argument("--apply-tag", action="store_true", help="Apply tag to flagged replication groups & snapshots")
    p.add_argument("--tag-key", default="Cost:Review", help="Tag key (default: Cost:Review)")
    p.add_argument("--tag-value", default="elasticache-snapshot-retention", help="Tag value (default: elasticache-snapshot-retention)")
    p.add_argument("--max-tag", type=int, default=50, help="Max total tag operations (default: 50)")
    p.add_argument("--ci-exit-on-findings", action="store_true", help="Exit code 2 if any findings (CI integration)")
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


def add_tags(client, arn: str, key: str, value: str) -> Optional[str]:
    try:
        client.add_tags_to_resource(ResourceName=arn, Tags=[{"Key": key, "Value": value}])
        return None
    except Exception as e:
        return str(e)


def list_replication_groups(client) -> List[Dict[str, Any]]:
    try:
        resp = client.describe_replication_groups()
        return resp.get("ReplicationGroups", [])
    except Exception:
        return []


def list_snapshots(client) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    marker = None
    while True:
        kwargs: Dict[str, Any] = {}
        if marker:
            kwargs["Marker"] = marker
        resp = client.describe_snapshots(**kwargs)
        out.extend(resp.get("Snapshots", []) or [])
        marker = resp.get("Marker")
        if not marker:
            break
    return out


def snapshot_age_days(snap: Dict[str, Any]) -> Optional[int]:
    try:
        ts = snap.get("SnapshotCreateTime")
        if not ts:
            return None
        # boto3 returns datetime already in tz; convert to UTC naive for diff
        if ts.tzinfo:
            ts = ts.astimezone(dt.timezone.utc).replace(tzinfo=None)
        now = dt.datetime.utcnow()
        return (now - ts).days
    except Exception:
        return None


def main():
    args = parse_args()
    sess = session(args.profile)
    regions = discover_regions(sess, args.regions)

    findings: List[Dict[str, Any]] = []
    tag_ops = 0

    for region in regions:
        ec = sess.client("elasticache", region_name=region)

        # Replication groups retention
        rgs = list_replication_groups(ec)
        for rg in rgs:
            rgid = rg.get("ReplicationGroupId")
            if args.name_filter and args.name_filter not in (rgid or ""):
                continue
            retention = rg.get("SnapshotRetentionLimit")  # may be None
            if retention is not None and retention < args.min_retention:
                arn = rg.get("ARN") or rg.get("ReplicationGroupArn") or rgid
                rec = {
                    "region": region,
                    "type": "replication_group_retention",
                    "id": rgid,
                    "retention_limit": retention,
                    "min_required": args.min_retention,
                    "tag_attempted": False,
                    "tag_error": None,
                }
                if args.apply_tag and tag_ops < args.max_tag and arn:
                    err = add_tags(ec, arn, args.tag_key, args.tag_value)
                    rec["tag_attempted"] = True
                    rec["tag_error"] = err
                    if err is None:
                        tag_ops += 1
                findings.append(rec)

        # Manual snapshot ages
        snaps = list_snapshots(ec)
        for snap in snaps:
            name = snap.get("SnapshotName")
            if args.name_filter and args.name_filter not in (name or ""):
                continue
            age_days = snapshot_age_days(snap)
            if age_days is None:
                continue
            if age_days > args.max_manual_age_days:
                arn = snap.get("ARN") or name
                rec = {
                    "region": region,
                    "type": "manual_snapshot_age",
                    "snapshot_name": name,
                    "age_days": age_days,
                    "max_allowed": args.max_manual_age_days,
                    "tag_attempted": False,
                    "tag_error": None,
                }
                if args.apply_tag and tag_ops < args.max_tag and arn:
                    err = add_tags(ec, arn, args.tag_key, args.tag_value)
                    rec["tag_attempted"] = True
                    rec["tag_error"] = err
                    if err is None:
                        tag_ops += 1
                findings.append(rec)

    payload = {
        "regions": regions,
        "min_retention": args.min_retention,
        "max_manual_age_days": args.max_manual_age_days,
        "apply_tag": args.apply_tag,
        "tag_operations": tag_ops,
        "findings": findings,
    }

    if args.json:
        print(json.dumps(payload, indent=2))
        if args.ci_exit_on_findings and findings:
            return 2
        return 0

    if not findings:
        print("No ElastiCache snapshot retention or age issues found.")
        return 0

    header = ["Region", "Type", "ID/Snapshot", "Retention/Age", "Threshold", "Tagged"]
    rows = [header]
    for f in findings:
        if f["type"] == "replication_group_retention":
            rows.append([
                f["region"], f["type"], f["id"], f["retention_limit"], f["min_required"],
                ("Y" if f["tag_attempted"] and not f["tag_error"] else ("ERR" if f["tag_error"] else "N")),
            ])
        else:
            rows.append([
                f["region"], f["type"], f["snapshot_name"], f["age_days"], f["max_allowed"],
                ("Y" if f["tag_attempted"] and not f["tag_error"] else ("ERR" if f["tag_error"] else "N")),
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
        print("\nDry-run. Use --apply-tag to tag flagged replication groups & snapshots.")

    if args.ci_exit_on_findings and findings:
        return 2
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
