#!/usr/bin/env python3
"""
aws-rds-idle-instance-finder.py

Purpose:
  Identify underutilized (potentially over-provisioned) Amazon RDS DB instances by
  examining CloudWatch metrics over a historical look‑back window. Generates a
  concise report indicating instances that appear *idle* or *cold* most of the
  time so you can right‑size, stop (for supported engines), or migrate them.

Heuristics (all configurable via flags):
  - avg CPUUtilization below --cpu-threshold (default 5%)
  - avg DatabaseConnections below --conn-threshold (default 5 connections)
  - avg ReadIOPS + WriteIOPS below --iops-threshold (default 5 combined)
  - (optional) freeable memory mostly unused (future enhancement)

If ALL core thresholds are satisfied for the lookback, instance is flagged as IDLE.
If only SOME are satisfied, it's flagged as LOW.

Safe: Read‑only. Makes no changes to AWS resources.

Output:
  - Human readable table by default
  - Optional JSON with full metric details per instance

Requires:
  - boto3
  - AWS credentials with permissions: rds:DescribeDBInstances, cloudwatch:GetMetricStatistics

Example:
  python aws-rds-idle-instance-finder.py --regions us-east-1 us-west-2 --days 7 --json
  python aws-rds-idle-instance-finder.py --profile prod --cpu-threshold 3 --conn-threshold 2

Exit Codes:
  0 success (even if no idle instances)
  1 unexpected error

Notes:
  - Uses GetMetricStatistics (simpler, fewer API calls) instead of GetMetricData batching.
  - Granularity defaults to 5m if the window supports it; can be raised with --period.
  - For Aurora clusters, evaluates underlying instances individually.
"""
import argparse
import boto3
import datetime as dt
import json
import statistics
import sys
from typing import Dict, List, Optional, Tuple, Any

CW_NS = "AWS/RDS"

METRICS = {
    "CPUUtilization": {"stat": "Average", "unit": "Percent"},
    "DatabaseConnections": {"stat": "Average", "unit": "Count"},
    "ReadIOPS": {"stat": "Average", "unit": "Count"},
    "WriteIOPS": {"stat": "Average", "unit": "Count"},
}


def parse_args():
    p = argparse.ArgumentParser(description="Detect idle / low-utilization RDS DB instances")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: current profile's default or us-east-1 if none)")
    p.add_argument("--profile", help="AWS profile name", default=None)
    p.add_argument("--days", type=int, default=7, help="Lookback window in days")
    p.add_argument("--period", type=int, default=300, help="CloudWatch period in seconds (default 300)")
    p.add_argument("--cpu-threshold", type=float, default=5.0, help="Avg CPU threshold percent for idle classification")
    p.add_argument("--conn-threshold", type=float, default=5.0, help="Avg DB connections threshold for idle classification")
    p.add_argument("--iops-threshold", type=float, default=5.0, help="Avg combined (read+write) IOPS threshold for idle classification")
    p.add_argument("--min-datapoints", type=int, default=10, help="Minimum datapoints required per metric to evaluate")
    p.add_argument("--include-low", action="store_true", help="Show LOW classification (partial threshold matches) as well")
    p.add_argument("--json", action="store_true", help="Output JSON instead of table")
    p.add_argument("--identifier-filter", help="Substring filter on DBInstanceIdentifier")
    p.add_argument("--engine-filter", help="Substring filter on engine (e.g. postgres, mysql)")
    return p.parse_args()


def session_for_profile(profile: Optional[str]):
    if profile:
        return boto3.Session(profile_name=profile)
    return boto3.Session()


def discover_regions(sess: boto3.Session, explicit: Optional[List[str]]) -> List[str]:
    if explicit:
        return explicit
    try:
        ec2 = sess.client("ec2")
        resp = ec2.describe_regions(AllRegions=False)
        # Return a short canonical subset: filter opt-in regions by Endpoint if needed.
        return sorted([r["RegionName"] for r in resp["Regions"]])
    except Exception:
        # Fallback
        return ["us-east-1"]


def list_db_instances(rds) -> List[Dict[str, Any]]:
    out = []
    marker = None
    while True:
        kwargs = {"MaxRecords": 100}
        if marker:
            kwargs["Marker"] = marker
        resp = rds.describe_db_instances(**kwargs)
        out.extend(resp.get("DBInstances", []))
        marker = resp.get("Marker")
        if not marker:
            break
    return out


def fetch_metric(cw, metric: str, db_id: str, start: dt.datetime, end: dt.datetime, period: int, stat: str) -> List[float]:
    try:
        resp = cw.get_metric_statistics(
            Namespace=CW_NS,
            MetricName=metric,
            Dimensions=[{"Name": "DBInstanceIdentifier", "Value": db_id}],
            StartTime=start,
            EndTime=end,
            Period=period,
            Statistics=[stat],
        )
    except cw.exceptions.InvalidParameterValueException:
        return []
    points = resp.get("Datapoints", [])
    # Each point has stat key e.g. 'Average'.
    values = [p.get(stat) for p in points if stat in p]
    return values


def summarize_metrics(values: List[float]) -> Optional[Dict[str, float]]:
    if not values:
        return None
    return {
        "min": min(values),
        "max": max(values),
        "avg": sum(values)/len(values),
        "p50": statistics.median(values),
        "p90": percentile(values, 90),
        "n": len(values),
    }


def percentile(data: List[float], pct: float) -> float:
    if not data:
        return 0.0
    s = sorted(data)
    k = (len(s)-1) * (pct/100.0)
    f = int(k)
    c = min(f+1, len(s)-1)
    if f == c:
        return s[f]
    d0 = s[f] * (c - k)
    d1 = s[c] * (k - f)
    return d0 + d1


def classify(m: Dict[str, Dict[str, float]], thresholds: Dict[str, float], min_datapoints: int) -> Tuple[str, List[str]]:
    reasons = []
    hits = 0
    needed = 3  # core metrics considered
    # CPU
    cpu = m.get("CPUUtilization")
    if cpu and cpu["n"] >= min_datapoints and cpu["avg"] < thresholds["cpu"]:
        hits += 1
        reasons.append(f"CPU avg {cpu['avg']:.2f}% < {thresholds['cpu']}")
    # Connections
    conn = m.get("DatabaseConnections")
    if conn and conn["n"] >= min_datapoints and conn["avg"] < thresholds["conn"]:
        hits += 1
        reasons.append(f"Conns avg {conn['avg']:.2f} < {thresholds['conn']}")
    # IOPS (combined)
    r = m.get("ReadIOPS")
    w = m.get("WriteIOPS")
    if r and w and r["n"] >= min_datapoints and w["n"] >= min_datapoints:
        combined_avg = (r["avg"] + w["avg"])
        if combined_avg < thresholds["iops"]:
            hits += 1
            reasons.append(f"IOPS avg {combined_avg:.2f} < {thresholds['iops']}")
    if hits == needed:
        return "IDLE", reasons
    if hits >= 2:
        return "LOW", reasons
    return "ACTIVE", reasons


def main():
    args = parse_args()
    sess = session_for_profile(args.profile)
    regions = discover_regions(sess, args.regions)

    end = dt.datetime.utcnow()
    start = end - dt.timedelta(days=args.days)

    thresholds = {
        "cpu": args.cpu_threshold,
        "conn": args.conn_threshold,
        "iops": args.iops_threshold,
    }

    output_rows = []

    for region in regions:
        rds = sess.client("rds", region_name=region)
        cw = sess.client("cloudwatch", region_name=region)
        try:
            instances = list_db_instances(rds)
        except Exception as e:
            print(f"WARN region {region} list_db_instances failed: {e}", file=sys.stderr)
            continue

        for inst in instances:
            ident = inst.get("DBInstanceIdentifier")
            engine = inst.get("Engine")
            clazz = inst.get("DBInstanceClass")
            multi = inst.get("MultiAZ")
            storage_type = inst.get("StorageType")
            arn = inst.get("DBInstanceArn")

            if args.identifier_filter and args.identifier_filter not in ident:
                continue
            if args.engine_filter and args.engine_filter.lower() not in engine.lower():
                continue

            metrics_summary: Dict[str, Dict[str, float]] = {}
            for metric_name, meta in METRICS.items():
                values = fetch_metric(cw, metric_name, ident, start, end, args.period, meta["stat"])
                summ = summarize_metrics(values)
                if summ:
                    metrics_summary[metric_name] = summ

            status, reasons = classify(metrics_summary, thresholds, args.min_datapoints)
            if status == "LOW" and not args.include_low:
                # We'll skip if user didn't ask to include low
                pass
            # Determine cost hint (rough) based on instance class size letter (t3.medium -> medium)
            size_hint = clazz.split(".")[-1] if clazz else "?"
            suggest = []
            if status in ("IDLE", "LOW"):
                if status == "IDLE":
                    suggest.append("Consider stopping (if supported) or downsizing instance class")
                elif status == "LOW":
                    suggest.append("Consider downsizing or enabling autoscaling where possible")
                if multi:
                    suggest.append("Evaluate need for MultiAZ to reduce standby cost")
                if storage_type and storage_type.lower() == "gp2":
                    suggest.append("Consider gp3 migration for cost baseline improvements")

            row = {
                "region": region,
                "identifier": ident,
                "engine": engine,
                "class": clazz,
                "size_hint": size_hint,
                "status": status,
                "reasons": reasons,
                "multi_az": multi,
                "storage_type": storage_type,
                "metrics": metrics_summary,
                "suggestions": suggest,
                "arn": arn,
            }
            # Only keep ACTIVE if producing JSON? We'll filter for human output.
            output_rows.append(row)

    if args.json:
        if not args.include_low:
            filtered = [r for r in output_rows if r["status"] == "IDLE"]
        else:
            filtered = [r for r in output_rows if r["status"] in ("IDLE", "LOW")]
        print(json.dumps({
            "scanned_regions": regions,
            "lookback_days": args.days,
            "period": args.period,
            "thresholds": thresholds,
            "instances": filtered,
        }, indent=2, default=str))
        return 0

    # Human table
    rows = []
    header = ["Region", "Identifier", "Engine", "Class", "Status", "CPUavg%", "ConnAvg", "IOPSAvg", "Reasons"]
    rows.append(header)
    for r in output_rows:
        if r["status"] == "ACTIVE":
            continue
        if r["status"] == "LOW" and not args.include_low:
            continue
        cpu_avg = r["metrics"].get("CPUUtilization", {}).get("avg", "-")
        conn_avg = r["metrics"].get("DatabaseConnections", {}).get("avg", "-")
        r_iops = r["metrics"].get("ReadIOPS", {}).get("avg", 0)
        w_iops = r["metrics"].get("WriteIOPS", {}).get("avg", 0)
        iops_avg = r_iops + w_iops if r_iops != 0 or w_iops != 0 else "-"
        reasons = "; ".join(r["reasons"]) if r["reasons"] else "-"
        rows.append([
            r["region"], r["identifier"], r["engine"], r["class"], r["status"],
            f"{cpu_avg:.2f}" if isinstance(cpu_avg, float) else cpu_avg,
            f"{conn_avg:.2f}" if isinstance(conn_avg, float) else conn_avg,
            f"{iops_avg:.2f}" if isinstance(iops_avg, float) else iops_avg,
            reasons,
        ])

    if len(rows) == 1:
        print("No idle (or low) RDS instances found under current thresholds.")
        return 0

    col_widths = [max(len(str(row[i])) for row in rows) for i in range(len(rows[0]))]
    for i, row in enumerate(rows):
        line = "  ".join(str(cell).ljust(col_widths[idx]) for idx, cell in enumerate(row))
        if i == 0:
            print(line)
            print("  ".join("-" * w for w in col_widths))
        else:
            print(line)

    print("\nSuggestions: Evaluate flagged instances; consider performance insights before resizing. Always test changes in lower environments.")
    return 0


if __name__ == "__main__":
    try:
        code = main()
        sys.exit(code)
    except KeyboardInterrupt:
        print("Interrupted", file=sys.stderr)
        sys.exit(130)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
