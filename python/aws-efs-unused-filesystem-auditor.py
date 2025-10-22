#!/usr/bin/env python3
"""
aws-efs-unused-filesystem-auditor.py

Purpose:
  Identify potentially unused or low-activity Amazon EFS file systems across regions using
  CloudWatch metrics and configuration (mount targets). Optionally tag candidates for review.

Features:
  - Multi-region scan (default: all enabled)
  - Signals:
      * Zero mount targets (likely unused)
      * Low I/O over window via TotalIOBytes (Sum)
      * Low average ClientConnections over window
  - Filters: --name-filter on FileSystemId or Name tag, --required-tag Key=Value (repeatable)
  - Actions: --apply-tag with --tag-key/--tag-value and --max-apply (dry-run by default)
  - Output: human-readable table or --json

Permissions:
  - efs:DescribeFileSystems, efs:DescribeMountTargets, efs:ListTagsForResource, efs:TagResource
  - cloudwatch:GetMetricStatistics
  - ec2:DescribeRegions

Examples:
  python aws-efs-unused-filesystem-auditor.py --regions us-east-1 us-west-2 --json
  python aws-efs-unused-filesystem-auditor.py --min-bytes 10485760 --max-avg-connections 0.1 --apply-tag --max-apply 20

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


CW_NS = "AWS/EFS"


def parse_args():
    p = argparse.ArgumentParser(description="Audit EFS file systems for low/zero usage (dry-run by default)")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all enabled)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--window-days", type=int, default=14, help="CloudWatch lookback window in days (default: 14)")
    p.add_argument("--period", type=int, default=3600, help="Metric period in seconds (default: 3600)")
    p.add_argument("--min-bytes", type=int, default=0, help="Minimum TotalIOBytes over window to be considered active (default: 0)")
    p.add_argument("--max-avg-connections", type=float, default=0.1, help="Max avg ClientConnections to still be considered idle (default: 0.1)")
    p.add_argument("--name-filter", help="Substring filter on FileSystemId or Name tag")
    p.add_argument("--required-tag", action="append", help="Require Tag Key=Value (repeat)")
    p.add_argument("--apply-tag", action="store_true", help="Tag flagged EFS file systems for review")
    p.add_argument("--tag-key", default="Cost:Review", help="Tag key (default: Cost:Review)")
    p.add_argument("--tag-value", default="efs-unused-candidate", help="Tag value (default: efs-unused-candidate)")
    p.add_argument("--max-apply", type=int, default=50, help="Max file systems to tag (default: 50)")
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


def list_file_systems(efs) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    marker = None
    while True:
        kwargs: Dict[str, Any] = {}
        if marker:
            kwargs["Marker"] = marker
        resp = efs.describe_file_systems(**kwargs)
        out.extend(resp.get("FileSystems", []) or [])
        marker = resp.get("NextMarker")
        if not marker:
            break
    return out


def list_mount_targets(efs, fs_id: str) -> List[Dict[str, Any]]:
    try:
        out: List[Dict[str, Any]] = []
        marker = None
        while True:
            kwargs: Dict[str, Any] = {"FileSystemId": fs_id}
            if marker:
                kwargs["Marker"] = marker
            resp = efs.describe_mount_targets(**kwargs)
            out.extend(resp.get("MountTargets", []) or [])
            marker = resp.get("NextMarker")
            if not marker:
                break
        return out
    except Exception:
        return []


def list_tags(efs, fs_id: str) -> Dict[str, str]:
    try:
        resp = efs.list_tags_for_resource(ResourceId=fs_id)
        return {t.get("Key"): t.get("Value") for t in resp.get("Tags", [])}
    except Exception:
        return {}


def cw_sum_metric(cw, fs_id: str, metric_name: str, start: dt.datetime, end: dt.datetime, period: int) -> float:
    try:
        resp = cw.get_metric_statistics(
            Namespace=CW_NS,
            MetricName=metric_name,
            Dimensions=[{"Name": "FileSystemId", "Value": fs_id}],
            StartTime=start,
            EndTime=end,
            Period=period,
            Statistics=["Sum"],
        )
        return float(sum(p.get("Sum", 0.0) for p in resp.get("Datapoints", [])))
    except Exception:
        return 0.0


def cw_avg_metric(cw, fs_id: str, metric_name: str, start: dt.datetime, end: dt.datetime, period: int) -> float:
    try:
        resp = cw.get_metric_statistics(
            Namespace=CW_NS,
            MetricName=metric_name,
            Dimensions=[{"Name": "FileSystemId", "Value": fs_id}],
            StartTime=start,
            EndTime=end,
            Period=period,
            Statistics=["Average"],
        )
        pts = resp.get("Datapoints", [])
        if not pts:
            return 0.0
        vals = [float(p.get("Average", 0.0)) for p in pts]
        return sum(vals) / len(vals)
    except Exception:
        return 0.0


def tag_fs(efs, fs_id: str, key: str, value: str) -> Optional[str]:
    try:
        efs.tag_resource(ResourceId=fs_id, Tags=[{"Key": key, "Value": value}])
        return None
    except Exception as e:
        return str(e)


def main():
    args = parse_args()
    sess = session(args.profile)
    regions = discover_regions(sess, args.regions)
    needed_tags = parse_tag_filters(args.required_tag)

    end = dt.datetime.utcnow()
    start = end - dt.timedelta(days=args.window_days)

    results = []
    applied = 0

    for region in regions:
        efs = sess.client("efs", region_name=region)
        cw = sess.client("cloudwatch", region_name=region)
        try:
            filesystems = list_file_systems(efs)
        except Exception as e:
            print(f"WARN region {region} list EFS file systems failed: {e}", file=sys.stderr)
            continue
        for fs in filesystems:
            fs_id = fs.get("FileSystemId")
            name_tag = None
            tags = list_tags(efs, fs_id)
            if tags:
                name_tag = tags.get("Name")
            if args.name_filter and (args.name_filter not in (name_tag or "") and args.name_filter not in fs_id):
                continue
            if needed_tags:
                ok = True
                for k, v in needed_tags.items():
                    if tags.get(k) != v:
                        ok = False
                        break
                if not ok:
                    continue

            mounts = list_mount_targets(efs, fs_id)
            mount_count = len(mounts)

            total_bytes = cw_sum_metric(cw, fs_id, "TotalIOBytes", start, end, args.period)
            avg_conns = cw_avg_metric(cw, fs_id, "ClientConnections", start, end, args.period)

            no_mounts = mount_count == 0
            low_activity = (total_bytes <= args.min_bytes) and (avg_conns <= args.max_avg_connections)

            flagged = no_mounts or low_activity
            if not flagged:
                continue

            rec = {
                "region": region,
                "file_system_id": fs_id,
                "name": name_tag,
                "mount_targets": mount_count,
                "total_io_bytes": total_bytes,
                "avg_client_connections": avg_conns,
                "flagged": flagged,
                "tag_attempted": False,
                "tag_error": None,
            }

            if args.apply_tag and applied < args.max_apply:
                err = tag_fs(efs, fs_id, args.tag_key, args.tag_value)
                rec["tag_attempted"] = True
                rec["tag_error"] = err
                if err is None:
                    applied += 1

            results.append(rec)

    payload = {
        "regions": regions,
        "window_days": args.window_days,
        "min_bytes": args.min_bytes,
        "max_avg_connections": args.max_avg_connections,
        "apply_tag": args.apply_tag,
        "applied": applied,
        "results": results,
    }

    if args.json:
        print(json.dumps(payload, indent=2))
        return 0

    if not results:
        print("No unused EFS file systems found under current thresholds.")
        return 0

    header = ["Region", "FileSystemId", "Name", "Mounts", "TotalIOBytes", "AvgConnections", "Tagged"]
    rows = [header]
    for r in results:
        rows.append([
            r["region"], r["file_system_id"], r.get("name") or "-",
            r["mount_targets"], int(r["total_io_bytes"]), f"{r['avg_client_connections']:.2f}",
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
