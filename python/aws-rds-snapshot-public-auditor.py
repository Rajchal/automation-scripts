#!/usr/bin/env python3
"""
aws-rds-snapshot-public-auditor.py

Purpose:
  Detect publicly accessible RDS snapshots (DB and Aurora DB Cluster snapshots) and optionally
  revoke public access by removing the 'all' restore permission. This helps prevent data leakage.

Features:
  - Multi-region scan (default: all enabled regions)
  - Scans both DB snapshots and DB cluster snapshots (Aurora)
  - Manual snapshots only (automated snapshots cannot be shared)
  - Filters:
      * --name-filter substring on snapshot identifier
      * --engine-filter substring on engine (e.g., 'aurora', 'mysql', 'postgres')
      * --older-than-days N (based on SnapshotCreateTime)
  - Optional remediation: --apply to remove 'all' from restore permissions (make private)
  - Safety caps with --max-apply
  - JSON or human-readable output

Permissions:
  - rds:DescribeDBSnapshots, rds:DescribeDBClusterSnapshots
  - rds:DescribeDBSnapshotAttributes, rds:DescribeDBClusterSnapshotAttributes
  - rds:ModifyDBSnapshotAttribute, rds:ModifyDBClusterSnapshotAttribute
  - ec2:DescribeRegions (for region discovery)

Examples:
  python aws-rds-snapshot-public-auditor.py --json
  python aws-rds-snapshot-public-auditor.py --engine-filter postgres --apply --max-apply 10

Exit Codes:
  0 success
  1 unexpected error
"""
import argparse
import boto3
import datetime as dt
import json
import sys
from typing import Any, Dict, List, Optional


def parse_args():
    p = argparse.ArgumentParser(description="Audit public RDS snapshots and optionally remediate")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all enabled)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--name-filter", help="Substring filter on snapshot identifier")
    p.add_argument("--engine-filter", help="Substring filter on engine name")
    p.add_argument("--older-than-days", type=int, help="Only include snapshots older than N days")
    p.add_argument("--apply", action="store_true", help="Remove public access from flagged snapshots")
    p.add_argument("--max-apply", type=int, default=50, help="Max snapshots to modify (default: 50)")
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


def list_db_snapshots(rds, snapshot_type: str = "manual") -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    token = None
    while True:
        kwargs = {"SnapshotType": snapshot_type, "MaxRecords": 100}
        if token:
            kwargs["Marker"] = token
        resp = rds.describe_db_snapshots(**kwargs)
        out.extend(resp.get("DBSnapshots", []))
        token = resp.get("Marker")
        if not token:
            break
    return out


def list_cluster_snapshots(rds, snapshot_type: str = "manual") -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    token = None
    while True:
        kwargs = {"SnapshotType": snapshot_type, "MaxRecords": 100}
        if token:
            kwargs["Marker"] = token
        resp = rds.describe_db_cluster_snapshots(**kwargs)
        out.extend(resp.get("DBClusterSnapshots", []))
        token = resp.get("Marker")
        if not token:
            break
    return out


def db_snapshot_is_public(rds, snap_id: str) -> Optional[bool]:
    try:
        resp = rds.describe_db_snapshot_attributes(DBSnapshotIdentifier=snap_id)
        for attr in resp.get("DBSnapshotAttributesResult", {}).get("DBSnapshotAttributes", []):
            if attr.get("AttributeName") == "restore":
                vals = attr.get("AttributeValues", [])
                return "all" in vals
        return False
    except Exception:
        return None


def cluster_snapshot_is_public(rds, snap_id: str) -> Optional[bool]:
    try:
        resp = rds.describe_db_cluster_snapshot_attributes(DBClusterSnapshotIdentifier=snap_id)
        for attr in resp.get("DBClusterSnapshotAttributesResult", {}).get("DBClusterSnapshotAttributes", []):
            if attr.get("AttributeName") == "restore":
                vals = attr.get("AttributeValues", [])
                return "all" in vals
        return False
    except Exception:
        return None


def revoke_db_snapshot_public(rds, snap_id: str) -> Optional[str]:
    try:
        rds.modify_db_snapshot_attribute(
            DBSnapshotIdentifier=snap_id,
            AttributeName="restore",
            ValuesToRemove=["all"],
        )
        return None
    except Exception as e:
        return str(e)


def revoke_cluster_snapshot_public(rds, snap_id: str) -> Optional[str]:
    try:
        rds.modify_db_cluster_snapshot_attribute(
            DBClusterSnapshotIdentifier=snap_id,
            AttributeName="restore",
            ValuesToRemove=["all"],
        )
        return None
    except Exception as e:
        return str(e)


def main():
    args = parse_args()
    sess = session(args.profile)
    regions = discover_regions(sess, args.regions)
    now = dt.datetime.utcnow()

    results = []
    applied = 0

    for region in regions:
        rds = sess.client("rds", region_name=region)
        try:
            db_snaps = list_db_snapshots(rds)
        except Exception as e:
            print(f"WARN region {region} list DB snapshots failed: {e}", file=sys.stderr)
            db_snaps = []
        try:
            cl_snaps = list_cluster_snapshots(rds)
        except Exception as e:
            print(f"WARN region {region} list DB cluster snapshots failed: {e}", file=sys.stderr)
            cl_snaps = []

        # DB Snapshots
        for s in db_snaps:
            snap_id = s.get("DBSnapshotIdentifier")
            eng = (s.get("Engine") or "").lower()
            if args.name_filter and args.name_filter not in snap_id:
                continue
            if args.engine_filter and (args.engine_filter.lower() not in eng):
                continue
            age_days = None
            ts = s.get("SnapshotCreateTime")
            if isinstance(ts, dt.datetime):
                if ts.tzinfo:
                    ts = ts.astimezone(dt.timezone.utc).replace(tzinfo=None)
                age_days = (now - ts).days
            if args.older_than_days is not None:
                if age_days is None or age_days < args.older_than_days:
                    continue

            is_public = db_snapshot_is_public(rds, snap_id)
            if not is_public:
                continue

            rec = {
                "region": region,
                "type": "db",
                "snapshot_id": snap_id,
                "db_instance_identifier": s.get("DBInstanceIdentifier"),
                "engine": s.get("Engine"),
                "snapshot_type": s.get("SnapshotType"),
                "public": is_public,
                "age_days": age_days,
                "apply_attempted": False,
                "apply_error": None,
            }
            if args.apply and applied < args.max_apply and is_public:
                err = revoke_db_snapshot_public(rds, snap_id)
                rec["apply_attempted"] = True
                rec["apply_error"] = err
                if err is None:
                    applied += 1
            results.append(rec)

        # DB Cluster Snapshots
        for s in cl_snaps:
            snap_id = s.get("DBClusterSnapshotIdentifier")
            eng = (s.get("Engine") or "").lower()
            if args.name_filter and args.name_filter not in snap_id:
                continue
            if args.engine_filter and (args.engine_filter.lower() not in eng):
                continue
            age_days = None
            ts = s.get("SnapshotCreateTime")
            if isinstance(ts, dt.datetime):
                if ts.tzinfo:
                    ts = ts.astimezone(dt.timezone.utc).replace(tzinfo=None)
                age_days = (now - ts).days
            if args.older_than_days is not None:
                if age_days is None or age_days < args.older_than_days:
                    continue

            is_public = cluster_snapshot_is_public(rds, snap_id)
            if not is_public:
                continue

            rec = {
                "region": region,
                "type": "cluster",
                "snapshot_id": snap_id,
                "db_cluster_identifier": s.get("DBClusterIdentifier"),
                "engine": s.get("Engine"),
                "snapshot_type": s.get("SnapshotType"),
                "public": is_public,
                "age_days": age_days,
                "apply_attempted": False,
                "apply_error": None,
            }
            if args.apply and applied < args.max_apply and is_public:
                err = revoke_cluster_snapshot_public(rds, snap_id)
                rec["apply_attempted"] = True
                rec["apply_error"] = err
                if err is None:
                    applied += 1
            results.append(rec)

    payload = {
        "regions": regions,
        "apply": args.apply,
        "applied": applied,
        "results": results,
    }

    if args.json:
        print(json.dumps(payload, indent=2, default=str))
        return 0

    if not results:
        print("No publicly accessible RDS snapshots found under current filters.")
        return 0

    header = ["Region", "Type", "SnapshotId", "Engine", "Age(d)", "Applied"]
    rows = [header]
    for r in results:
        rows.append([
            r["region"], r["type"], r["snapshot_id"], r.get("engine") or "-", r.get("age_days"),
            ("Y" if r["apply_attempted"] and not r["apply_error"] else ("ERR" if r["apply_error"] else "N")),
        ])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = '  '.join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print('  '.join('-' * w for w in widths))
        else:
            print(line)
    if not args.apply:
        print("\nDry-run. Use --apply to revoke public access (remove 'all' restore permission).")
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
