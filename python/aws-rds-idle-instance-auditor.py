#!/usr/bin/env python3
"""
aws-rds-idle-instance-auditor.py

Purpose:
  Identify potentially idle or under-utilized RDS DB instances and Aurora DB clusters using
  CloudWatch metrics. Optionally tag flagged resources for review (no destructive actions).

Heuristic (all must be satisfied to flag):
  - Average CPUUtilization <= --max-cpu-avg (default 2.0)
  - Average DatabaseConnections <= --max-connections (default 3)
  - Sum(ReadIOPS + WriteIOPS) over window <= --max-iops-sum (default 100)

Features:
  - Scans DB instances via describe_db_instances and DB clusters via describe_db_clusters
  - Configurable lookback window (--window-days, default 7) and metric period (--period, default 3600)
  - Optional tagging with --apply-tag and safety cap --max-tag
  - JSON or human-readable output

Safety:
  - This script does not modify or delete DB resources unless tagging is explicitly requested.

Permissions:
  - rds:DescribeDBInstances, rds:DescribeDBClusters, rds:AddTagsToResource (or AddTagsToResource for snapshots)
  - cloudwatch:GetMetricStatistics
  - ec2:DescribeRegions

Examples:
  python aws-rds-idle-instance-auditor.py --regions us-east-1 --json
  python aws-rds-idle-instance-auditor.py --apply-tag --max-tag 20

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

CW_NS = "AWS/RDS"


def parse_args():
    p = argparse.ArgumentParser(description="Audit idle RDS DB instances and Aurora clusters (dry-run by default)")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all enabled)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--window-days", type=int, default=7, help="CloudWatch lookback window in days (default: 7)")
    p.add_argument("--period", type=int, default=3600, help="Metric period seconds (default: 3600)")
    p.add_argument("--max-cpu-avg", type=float, default=2.0, help="Max average CPUUtilization to be idle (default: 2.0)")
    p.add_argument("--max-connections", type=float, default=3.0, help="Max average DatabaseConnections to be idle (default: 3)")
    p.add_argument("--max-iops-sum", type=float, default=100.0, help="Max sum of ReadIOPS+WriteIOPS over window (default: 100)")
    p.add_argument("--apply-tag", action="store_true", help="Apply a tag to flagged resources (dry-run by default)")
    p.add_argument("--tag-key", default="Cost:Review", help="Tag key (default: Cost:Review)")
    p.add_argument("--tag-value", default="rds-idle-candidate", help="Tag value (default: rds-idle-candidate)")
    p.add_argument("--max-tag", type=int, default=50, help="Max resources to tag (default: 50)")
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


def cw_avg_metric(cw, name: str, metric: str, dimension_name: str, start: dt.datetime, end: dt.datetime, period: int) -> Optional[float]:
    try:
        resp = cw.get_metric_statistics(
            Namespace=CW_NS,
            MetricName=metric,
            Dimensions=[{"Name": dimension_name, "Value": name}],
            StartTime=start,
            EndTime=end,
            Period=period,
            Statistics=["Average"],
        )
        pts = resp.get("Datapoints", [])
        if not pts:
            return None
        vals = [float(p.get("Average", 0.0)) for p in pts]
        return sum(vals) / len(vals)
    except Exception:
        return None


def cw_sum_metric(cw, name: str, metric: str, dimension_name: str, start: dt.datetime, end: dt.datetime, period: int) -> Optional[float]:
    try:
        resp = cw.get_metric_statistics(
            Namespace=CW_NS,
            MetricName=metric,
            Dimensions=[{"Name": dimension_name, "Value": name}],
            StartTime=start,
            EndTime=end,
            Period=period,
            Statistics=["Sum"],
        )
        pts = resp.get("Datapoints", [])
        if not pts:
            return None
        return float(sum(p.get("Sum", 0.0) for p in pts))
    except Exception:
        return None


def add_tags(rds, arn: str, key: str, value: str) -> Optional[str]:
    try:
        # RDS supports add_tags_to_resource with ResourceName=ARN
        rds.add_tags_to_resource(ResourceName=arn, Tags=[{"Key": key, "Value": value}])
        return None
    except Exception as e:
        return str(e)


def list_db_instances(rds) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    marker = None
    while True:
        kwargs: Dict[str, Any] = {}
        if marker:
            kwargs["Marker"] = marker
        resp = rds.describe_db_instances(**kwargs)
        out.extend(resp.get("DBInstances", []) or [])
        marker = resp.get("Marker")
        if not marker:
            break
    return out


def list_db_clusters(rds) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    marker = None
    while True:
        kwargs: Dict[str, Any] = {}
        if marker:
            kwargs["Marker"] = marker
        resp = rds.describe_db_clusters(**kwargs)
        out.extend(resp.get("DBClusters", []) or [])
        marker = resp.get("Marker")
        if not marker:
            break
    return out


def main():
    args = parse_args()
    sess = session(args.profile)
    regions = discover_regions(sess, args.regions)

    end = dt.datetime.utcnow()
    start = end - dt.timedelta(days=args.window_days)

    findings: List[Dict[str, Any]] = []
    tagged = 0

    for region in regions:
        rds = sess.client("rds", region_name=region)
        cw = sess.client("cloudwatch", region_name=region)

        # DB Instances
        try:
            dbs = list_db_instances(rds)
        except Exception as e:
            print(f"WARN region {region} describe_db_instances failed: {e}", file=sys.stderr)
            dbs = []

        for db in dbs:
            dbid = db.get("DBInstanceIdentifier")
            arn = db.get("DBInstanceArn") or db.get("DBInstanceIdentifier")

            cpu = cw_avg_metric(cw, dbid, "CPUUtilization", "DBInstanceIdentifier", start, end, args.period)
            conn = cw_avg_metric(cw, dbid, "DatabaseConnections", "DBInstanceIdentifier", start, end, args.period)
            read_iops = cw_sum_metric(cw, dbid, "ReadIOPS", "DBInstanceIdentifier", start, end, args.period) or 0.0
            write_iops = cw_sum_metric(cw, dbid, "WriteIOPS", "DBInstanceIdentifier", start, end, args.period) or 0.0
            iops_sum = read_iops + write_iops

            # Conservative: if any metric missing, don't flag
            if cpu is None or conn is None:
                continue

            idle = (cpu <= args.max_cpu_avg) and (conn <= args.max_connections) and (iops_sum <= args.max_iops_sum)
            if not idle:
                continue

            rec = {
                "region": region,
                "type": "db_instance",
                "id": dbid,
                "arn": arn,
                "cpu_avg": cpu,
                "db_connections": conn,
                "iops_sum": iops_sum,
                "tag_attempted": False,
                "tag_error": None,
            }

            if args.apply_tag and arn and tagged < args.max_tag:
                err = add_tags(rds, arn, args.tag_key, args.tag_value)
                rec["tag_attempted"] = True
                rec["tag_error"] = err
                if err is None:
                    tagged += 1

            findings.append(rec)

        # DB Clusters (Aurora)
        try:
            clusters = list_db_clusters(rds)
        except Exception as e:
            print(f"WARN region {region} describe_db_clusters failed: {e}", file=sys.stderr)
            clusters = []

        for cl in clusters:
            clid = cl.get("DBClusterIdentifier")
            arn = cl.get("DBClusterArn") or cl.get("DBClusterIdentifier")

            cpu = cw_avg_metric(cw, clid, "CPUUtilization", "DBClusterIdentifier", start, end, args.period)
            conn = cw_avg_metric(cw, clid, "DatabaseConnections", "DBClusterIdentifier", start, end, args.period)
            read_iops = cw_sum_metric(cw, clid, "ReadIOPS", "DBClusterIdentifier", start, end, args.period) or 0.0
            write_iops = cw_sum_metric(cw, clid, "WriteIOPS", "DBClusterIdentifier", start, end, args.period) or 0.0
            iops_sum = read_iops + write_iops

            if cpu is None or conn is None:
                continue

            idle = (cpu <= args.max_cpu_avg) and (conn <= args.max_connections) and (iops_sum <= args.max_iops_sum)
            if not idle:
                continue

            rec = {
                "region": region,
                "type": "db_cluster",
                "id": clid,
                "arn": arn,
                "cpu_avg": cpu,
                "db_connections": conn,
                "iops_sum": iops_sum,
                "tag_attempted": False,
                "tag_error": None,
            }

            if args.apply_tag and arn and tagged < args.max_tag:
                err = add_tags(rds, arn, args.tag_key, args.tag_value)
                rec["tag_attempted"] = True
                rec["tag_error"] = err
                if err is None:
                    tagged += 1

            findings.append(rec)

    payload = {
        "regions": regions,
        "window_days": args.window_days,
        "max_cpu_avg": args.max_cpu_avg,
        "max_connections": args.max_connections,
        "max_iops_sum": args.max_iops_sum,
        "apply_tag": args.apply_tag,
        "tagged": tagged,
        "findings": findings,
    }

    if args.json:
        print(json.dumps(payload, indent=2))
        if args.ci_exit_on_findings and findings:
            return 2
        return 0

    if not findings:
        print("No idle RDS instances or clusters found under current thresholds.")
        return 0

    header = ["Region", "Type", "ID", "CPUAvg", "DBConns", "IOPS(sum)", "Tagged"]
    rows = [header]
    for f in findings:
        rows.append([
            f["region"], f["type"], f["id"], f"{f['cpu_avg']:.2f}", f"{f['db_connections']:.1f}", f"{f['iops_sum']:.1f}",
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
        print("\nDry-run. Use --apply-tag to mark candidates for review.")

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
