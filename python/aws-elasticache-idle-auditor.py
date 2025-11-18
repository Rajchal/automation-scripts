#!/usr/bin/env python3
"""
aws-elasticache-idle-auditor.py

Purpose:
  Identify potentially idle or under-utilized ElastiCache clusters/replication-groups across regions
  using CloudWatch metrics. Optionally tag flagged resources for review. This does NOT delete instances.

Features:
  - Multi-region scan (default: all enabled)
  - CloudWatch metrics window (default 7 days) and period (default 3600s)
  - Thresholds (idle when all satisfied):
      * --max-connections (Sum/CurrConnections) default: 5
      * --max-cpu-avg (Average CPUUtilization) default: 5.0
  - Optional tagging with --apply-tag and safety cap --max-apply
  - JSON or human-readable output

Notes & Safety:
  - Tagging is metadata-only and safe. No deletes or config changes are performed.
  - CloudWatch namespace is AWS/ElastiCache.

Permissions:
  - elasticache:DescribeReplicationGroups, elasticache:DescribeCacheClusters, elasticache:AddTagsToResource
  - cloudwatch:GetMetricStatistics, ec2:DescribeRegions

Examples:
  python aws-elasticache-idle-auditor.py --regions us-east-1 us-west-2 --json
  python aws-elasticache-idle-auditor.py --max-connections 10 --apply-tag --max-apply 5

Exit Codes:
  0 success
  1 unexpected error
"""
import argparse
import boto3
import datetime as dt
import json
import sys
from typing import Any, Dict, List, Optional, Tuple

CW_NS = "AWS/ElastiCache"


def parse_args():
    p = argparse.ArgumentParser(description="Audit idle ElastiCache clusters/replication-groups (dry-run by default)")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all enabled)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--window-days", type=int, default=7, help="CloudWatch lookback window in days (default: 7)")
    p.add_argument("--period", type=int, default=3600, help="Metric period in seconds (default: 3600)")
    p.add_argument("--max-connections", type=int, default=5, help="Maximum CurrConnections sum to consider idle (default: 5)")
    p.add_argument("--max-cpu-avg", type=float, default=5.0, help="Maximum CPUUtilization average to still consider idle (default: 5.0)")
    p.add_argument("--apply-tag", action="store_true", help="Apply a tag to flagged resources (dry-run by default)")
    p.add_argument("--tag-key", default="Cost:Review", help="Tag key (default: Cost:Review)")
    p.add_argument("--tag-value", default="elasticache-idle-candidate", help="Tag value (default: elasticache-idle-candidate)")
    p.add_argument("--max-apply", type=int, default=50, help="Max resources to tag (default: 50)")
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


def cw_sum_metric(cw, name: str, metric_name: str, dimension_name: str, start: dt.datetime, end: dt.datetime, period: int) -> float:
    try:
        resp = cw.get_metric_statistics(
            Namespace=CW_NS,
            MetricName=metric_name,
            Dimensions=[{"Name": dimension_name, "Value": name}],
            StartTime=start,
            EndTime=end,
            Period=period,
            Statistics=["Sum"],
        )
        return float(sum(p.get("Sum", 0.0) for p in resp.get("Datapoints", [])))
    except Exception:
        return 0.0


def cw_avg_metric(cw, name: str, metric_name: str, dimension_name: str, start: dt.datetime, end: dt.datetime, period: int) -> float:
    try:
        resp = cw.get_metric_statistics(
            Namespace=CW_NS,
            MetricName=metric_name,
            Dimensions=[{"Name": dimension_name, "Value": name}],
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


def add_tags(client, arn: str, key: str, value: str) -> Optional[str]:
    try:
        # ElastiCache uses AddTagsToResource / add_tags_to_resource
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


def list_cache_clusters(client) -> List[Dict[str, Any]]:
    try:
        resp = client.describe_cache_clusters(ShowCacheNodeInfo=False)
        return resp.get("CacheClusters", [])
    except Exception:
        return []


def main():
    args = parse_args()
    sess = session(args.profile)
    regions = discover_regions(sess, args.regions)

    end = dt.datetime.utcnow()
    start = end - dt.timedelta(days=args.window_days)

    results = []
    applied = 0

    for region in regions:
        ec = sess.client("elasticache", region_name=region)
        cw = sess.client("cloudwatch", region_name=region)

        # Check replication groups first (Redis replication groups)
        rgs = list_replication_groups(ec)
        for rg in rgs:
            rgid = rg.get("ReplicationGroupId")
            arn = rg.get("ARN") or rg.get("ReplicationGroupArn") or rg.get("ReplicationGroupId")

            # Prefer using ReplicationGroupId as dimension when supported
            conn_sum = cw_sum_metric(cw, rgid, "CurrConnections", "ReplicationGroupId", start, end, args.period)
            cpu_avg = cw_avg_metric(cw, rgid, "CPUUtilization", "ReplicationGroupId", start, end, args.period)

            is_idle = (conn_sum <= args.max_connections) and (cpu_avg <= args.max_cpu_avg)

            rec = {
                "region": region,
                "resource_type": "replication_group",
                "id": rgid,
                "arn": arn,
                "connections_sum": conn_sum,
                "cpu_avg": cpu_avg,
                "flagged_idle": is_idle,
                "tag_attempted": False,
                "tag_error": None,
            }

            if is_idle and args.apply_tag and arn and applied < args.max_apply:
                err = add_tags(ec, arn, args.tag_key, args.tag_value)
                rec["tag_attempted"] = True
                rec["tag_error"] = err
                if err is None:
                    applied += 1

            if is_idle:
                results.append(rec)

        # Also check standalone cache clusters (Memcached or single-node Redis)
        clusters = list_cache_clusters(ec)
        for cl in clusters:
            cid = cl.get("CacheClusterId")
            arn = cl.get("ARN") or cl.get("CacheClusterArn") or cl.get("CacheClusterId")

            # CacheCluster metrics often use CacheClusterId as dimension
            conn_sum = cw_sum_metric(cw, cid, "CurrConnections", "CacheClusterId", start, end, args.period)
            cpu_avg = cw_avg_metric(cw, cid, "CPUUtilization", "CacheClusterId", start, end, args.period)

            is_idle = (conn_sum <= args.max_connections) and (cpu_avg <= args.max_cpu_avg)

            rec = {
                "region": region,
                "resource_type": "cache_cluster",
                "id": cid,
                "arn": arn,
                "connections_sum": conn_sum,
                "cpu_avg": cpu_avg,
                "flagged_idle": is_idle,
                "tag_attempted": False,
                "tag_error": None,
            }

            if is_idle and args.apply_tag and arn and applied < args.max_apply:
                err = add_tags(ec, arn, args.tag_key, args.tag_value)
                rec["tag_attempted"] = True
                rec["tag_error"] = err
                if err is None:
                    applied += 1

            if is_idle:
                results.append(rec)

    payload = {
        "regions": regions,
        "window_days": args.window_days,
        "max_connections": args.max_connections,
        "max_cpu_avg": args.max_cpu_avg,
        "apply_tag": args.apply_tag,
        "applied": applied,
        "results": results,
    }

    if args.json:
        print(json.dumps(payload, indent=2))
        return 0

    if not results:
        print("No idle ElastiCache resources found under current thresholds.")
        return 0

    header = ["Region", "Type", "ID", "ConnSum", "CPUAvg", "Tagged"]
    rows = [header]
    for r in results:
        rows.append([
            r["region"], r["resource_type"], r["id"], int(r["connections_sum"]), f"{r['cpu_avg']:.2f}",
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
