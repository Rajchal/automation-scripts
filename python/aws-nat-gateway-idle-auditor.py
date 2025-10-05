#!/usr/bin/env python3
"""
aws-nat-gateway-idle-auditor.py

Purpose:
  Identify potentially idle or under-utilized NAT Gateways across regions to reduce costs.
  Uses CloudWatch metrics over a time window to gauge data processed and activity.

Features:
  - Multi-region scan (default: all enabled regions)
  - CloudWatch metrics window (default 14 days)
  - Thresholds:
      * --min-bytes: minimum total bytes over window to be considered "active" (default: 0)
      * --max-active-conn-avg: maximum average ActiveConnectionCount to still be considered "idle" (default: 0.1)
  - Optional route table check to count route tables targeting each NAT Gateway
  - Optional tagging of flagged NAT Gateways (dry-run by default)
  - JSON or human-readable output

Notes & Safety:
  - This is read-only unless --apply-tag is provided. Deleting NAT Gateways is disruptive; this tool does not delete.
  - Pricing varies by region; default pricing assumptions used:
      hourly_rate = 0.045 USD/hour, per_gb_rate = 0.045 USD/GB
    These can be overridden via flags; they are used for rough monthly estimates.

AWS Permissions:
  - ec2:DescribeNatGateways, ec2:DescribeRouteTables, ec2:DescribeRegions, ec2:CreateTags
  - cloudwatch:GetMetricStatistics or cloudwatch:GetMetricData

Examples:
  python aws-nat-gateway-idle-auditor.py --regions us-east-1 us-west-2 --window-days 14 --min-bytes 10485760 --json
  python aws-nat-gateway-idle-auditor.py --apply-tag --tag-key Cost:Review --tag-value candidate --max-apply 10

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


NAMESPACE = "AWS/NATGateway"
METRICS_BYTES = [
    "BytesInFromSource",
    "BytesOutToDestination",
    "BytesOutToSource",
    "BytesInFromDestination",
]
METRIC_ACTIVE_CONN = "ActiveConnectionCount"


def parse_args():
    p = argparse.ArgumentParser(description="Audit potentially idle NAT Gateways (dry-run by default)")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all enabled)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--window-days", type=int, default=14, help="CloudWatch lookback window in days (default: 14)")
    p.add_argument("--period", type=int, default=3600, help="Metric period in seconds (default: 3600)")
    p.add_argument("--min-bytes", type=int, default=0, help="Minimum total bytes over window to be considered active (default: 0)")
    p.add_argument("--max-active-conn-avg", type=float, default=0.1, help="Max average ActiveConnectionCount for idle (default: 0.1)")
    p.add_argument("--check-routes", action="store_true", help="Also count route tables pointing to each NAT GW")
    p.add_argument("--apply-tag", action="store_true", help="Apply tag to flagged NAT GWs (dry-run by default)")
    p.add_argument("--tag-key", default="Cost:Review", help="Tag key to apply to flagged NAT GWs (default: Cost:Review)")
    p.add_argument("--tag-value", default="idle-candidate", help="Tag value to apply (default: idle-candidate)")
    p.add_argument("--max-apply", type=int, default=50, help="Max resources to tag (default: 50)")
    p.add_argument("--hourly-rate", type=float, default=0.045, help="Hourly cost rate USD/hr (default: 0.045)")
    p.add_argument("--per-gb-rate", type=float, default=0.045, help="Data processing cost USD/GB (default: 0.045)")
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


def cw_sum_metric(cw, nat_id: str, metric_name: str, start: dt.datetime, end: dt.datetime, period: int) -> float:
    try:
        resp = cw.get_metric_statistics(
            Namespace=NAMESPACE,
            MetricName=metric_name,
            Dimensions=[{"Name": "NatGatewayId", "Value": nat_id}],
            StartTime=start,
            EndTime=end,
            Period=period,
            Statistics=["Sum"],
        )
        points = resp.get("Datapoints", [])
        return float(sum(p.get("Sum", 0.0) for p in points))
    except Exception:
        return 0.0


def cw_avg_metric(cw, nat_id: str, metric_name: str, start: dt.datetime, end: dt.datetime, period: int) -> float:
    try:
        resp = cw.get_metric_statistics(
            Namespace=NAMESPACE,
            MetricName=metric_name,
            Dimensions=[{"Name": "NatGatewayId", "Value": nat_id}],
            StartTime=start,
            EndTime=end,
            Period=period,
            Statistics=["Average"],
        )
        points = resp.get("Datapoints", [])
        if not points:
            return 0.0
        # Time-weighted simple average over returned intervals
        vals = [float(p.get("Average", 0.0)) for p in points]
        return sum(vals) / len(vals)
    except Exception:
        return 0.0


def list_nat_gateways(ec2):
    out = []
    token = None
    while True:
        kwargs = {"MaxResults": 200}
        if token:
            kwargs["NextToken"] = token
        resp = ec2.describe_nat_gateways(**kwargs)
        out.extend([ngw for ngw in resp.get("NatGateways", []) if ngw.get("State") == "available"])
        token = resp.get("NextToken")
        if not token:
            break
    return out


def count_routes_to_nat(ec2, nat_id: str) -> int:
    try:
        rts = []
        token = None
        while True:
            kwargs = {}
            if token:
                kwargs["NextToken"] = token
            resp = ec2.describe_route_tables(**kwargs)
            rts.extend(resp.get("RouteTables", []))
            token = resp.get("NextToken")
            if not token:
                break
        count = 0
        for rt in rts:
            for r in rt.get("Routes", []):
                if r.get("NatGatewayId") == nat_id:
                    count += 1
                    break
        return count
    except Exception:
        return 0


def apply_tag(ec2, nat_id: str, key: str, value: str) -> Optional[str]:
    try:
        ec2.create_tags(Resources=[nat_id], Tags=[{"Key": key, "Value": value}])
        return None
    except Exception as e:
        return str(e)


def estimate_cost(hourly_rate: float, per_gb_rate: float, total_bytes: float) -> Dict[str, float]:
    monthly_hours = 730.0
    data_gb = max(total_bytes, 0.0) / (1024.0 ** 3)
    return {
        "hourly_estimate_usd": hourly_rate,
        "monthly_estimate_usd": hourly_rate * monthly_hours + data_gb * per_gb_rate,
        "data_gb_window": data_gb,
    }


def main():
    args = parse_args()
    sess = session(args.profile)
    regions = discover_regions(sess, args.regions)

    end = dt.datetime.utcnow()
    start = end - dt.timedelta(days=args.window_days)

    results = []
    applied = 0

    for region in regions:
        ec2 = sess.client("ec2", region_name=region)
        cw = sess.client("cloudwatch", region_name=region)
        try:
            nat_gws = list_nat_gateways(ec2)
        except Exception as e:
            print(f"WARN region {region} list NAT Gateways failed: {e}", file=sys.stderr)
            continue
        for nat in nat_gws:
            nat_id = nat.get("NatGatewayId")
            name_tag = None
            for t in nat.get("Tags", []) or []:
                if t.get("Key") in ("Name", "name"):
                    name_tag = t.get("Value")
                    break
            total_bytes = 0.0
            for m in METRICS_BYTES:
                total_bytes += cw_sum_metric(cw, nat_id, m, start, end, args.period)
            avg_conn = cw_avg_metric(cw, nat_id, METRIC_ACTIVE_CONN, start, end, args.period)

            # Determine idle based on thresholds
            is_idle = (total_bytes <= args.min_bytes) and (avg_conn <= args.max_active_conn_avg)

            routes_count = None
            if args.check_routes:
                routes_count = count_routes_to_nat(ec2, nat_id)

            rec = {
                "region": region,
                "nat_gateway_id": nat_id,
                "name": name_tag,
                "total_bytes_window": total_bytes,
                "avg_active_conn": avg_conn,
                "routes_to_nat": routes_count,
                "flagged_idle": is_idle,
                "tag_attempted": False,
                "tag_error": None,
            }

            if is_idle and args.apply_tag and applied < args.max_apply:
                err = apply_tag(ec2, nat_id, args.tag_key, args.tag_value)
                rec["tag_attempted"] = True
                rec["tag_error"] = err
                if err is None:
                    applied += 1

            # Cost estimate for context
            rec.update(estimate_cost(args.hourly_rate, args.per_gb_rate, total_bytes))
            if is_idle:
                results.append(rec)

    payload = {
        "regions": regions,
        "window_days": args.window_days,
        "min_bytes": args.min_bytes,
        "max_active_conn_avg": args.max_active_conn_avg,
        "apply_tag": args.apply_tag,
        "applied": applied,
        "results": results,
    }

    if args.json:
        print(json.dumps(payload, indent=2))
        return 0

    if not results:
        print("No idle NAT Gateways found under current thresholds.")
        return 0

    header = ["Region", "NatGatewayId", "Name", "Data(GB)", "AvgConn", "Routes", "Tagged"]
    rows = [header]
    for r in results:
        rows.append([
            r["region"], r["nat_gateway_id"], r.get("name") or "-",
            f"{r['data_gb_window']:.2f}", f"{r['avg_active_conn']:.2f}",
            ("-" if r.get("routes_to_nat") is None else str(r.get("routes_to_nat"))),
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
