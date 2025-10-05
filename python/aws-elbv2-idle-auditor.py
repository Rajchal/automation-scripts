#!/usr/bin/env python3
"""
aws-elbv2-idle-auditor.py

Purpose:
  Identify potentially idle or under-utilized Application/Network Load Balancers (ALB/NLB)
  across regions using CloudWatch metrics, with optional tagging for review.

Features:
  - Multi-region scan (default: all enabled)
  - CloudWatch window/period options
  - Thresholds:
      * ALB: --min-requests (Sum of RequestCount)
      * NLB: --max-active-flows (Average of ActiveFlowCount)
      * Both: --min-bytes (Sum of ProcessedBytes)
  - Optional target group health check summary
  - Optional tagging for flagged LBs (dry-run by default)
  - JSON or human-readable output

Safety:
  - Read-only unless --apply-tag is provided. No deletes.

Permissions:
  - elasticloadbalancing:DescribeLoadBalancers, DescribeListeners, DescribeTargetGroups, DescribeTargetHealth, AddTags
  - cloudwatch:GetMetricStatistics
  - ec2:DescribeRegions

Examples:
  python aws-elbv2-idle-auditor.py --regions us-east-1 us-west-2 --window-days 14 --json
  python aws-elbv2-idle-auditor.py --min-requests 10 --min-bytes 10485760 --apply-tag --max-apply 20

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


ALB_NS = "AWS/ApplicationELB"
NLB_NS = "AWS/NetworkELB"


def parse_args():
    p = argparse.ArgumentParser(description="Audit potentially idle ALB/NLB (dry-run by default)")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all enabled)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--window-days", type=int, default=14, help="CloudWatch lookback window in days (default: 14)")
    p.add_argument("--period", type=int, default=3600, help="Metric period in seconds (default: 3600)")
    p.add_argument("--min-requests", type=int, default=0, help="ALB: minimum RequestCount sum to be considered active (default: 0)")
    p.add_argument("--max-active-flows", type=float, default=0.1, help="NLB: maximum avg ActiveFlowCount to still be considered idle (default: 0.1)")
    p.add_argument("--min-bytes", type=int, default=0, help="Minimum ProcessedBytes sum to be considered active (default: 0)")
    p.add_argument("--check-target-health", action="store_true", help="Summarize target health for attached target groups")
    p.add_argument("--apply-tag", action="store_true", help="Apply a tag to flagged LBs (dry-run by default)")
    p.add_argument("--tag-key", default="Cost:Review", help="Tag key (default: Cost:Review)")
    p.add_argument("--tag-value", default="idle-candidate", help="Tag value (default: idle-candidate)")
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


def lb_cw_dimension_from_arn(lb_arn: str) -> Optional[str]:
    # ARN format: arn:aws:elasticloadbalancing:region:acct:loadbalancer/{app|net}/name/hash
    try:
        idx = lb_arn.index(":loadbalancer/")
        return lb_arn[idx + len(":loadbalancer/"):]
    except Exception:
        return None


def cw_sum_metric(cw, namespace: str, lb_dim: str, metric_name: str, start: dt.datetime, end: dt.datetime, period: int) -> float:
    try:
        resp = cw.get_metric_statistics(
            Namespace=namespace,
            MetricName=metric_name,
            Dimensions=[{"Name": "LoadBalancer", "Value": lb_dim}],
            StartTime=start,
            EndTime=end,
            Period=period,
            Statistics=["Sum"],
        )
        return float(sum(p.get("Sum", 0.0) for p in resp.get("Datapoints", [])))
    except Exception:
        return 0.0


def cw_avg_metric(cw, namespace: str, lb_dim: str, metric_name: str, start: dt.datetime, end: dt.datetime, period: int) -> float:
    try:
        resp = cw.get_metric_statistics(
            Namespace=namespace,
            MetricName=metric_name,
            Dimensions=[{"Name": "LoadBalancer", "Value": lb_dim}],
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


def list_lbs(elbv2):
    lbs = []
    token = None
    while True:
        kwargs = {}
        if token:
            kwargs["Marker"] = token
        resp = elbv2.describe_load_balancers(**kwargs)
        lbs.extend(resp.get("LoadBalancers", []))
        token = resp.get("NextMarker")
        if not token:
            break
    return lbs


def list_target_groups_for_lb(elbv2, lb_arn: str) -> List[Dict[str, Any]]:
    tgs = []
    token = None
    while True:
        kwargs = {"LoadBalancerArn": lb_arn}
        if token:
            kwargs["Marker"] = token
        resp = elbv2.describe_target_groups(**kwargs)
        tgs.extend(resp.get("TargetGroups", []))
        token = resp.get("NextMarker")
        if not token:
            break
    return tgs


def target_health_summary(elbv2, tg_arn: str) -> Dict[str, int]:
    try:
        resp = elbv2.describe_target_health(TargetGroupArn=tg_arn)
        counts: Dict[str, int] = {}
        for th in resp.get("TargetHealthDescriptions", []):
            state = ((th.get("TargetHealth") or {}).get("State") or "unknown").lower()
            counts[state] = counts.get(state, 0) + 1
        return counts
    except Exception:
        return {}


def apply_tag(elbv2, lb_arn: str, key: str, value: str) -> Optional[str]:
    try:
        elbv2.add_tags(ResourceArns=[lb_arn], Tags=[{"Key": key, "Value": value}])
        return None
    except Exception as e:
        return str(e)


def main():
    args = parse_args()
    sess = session(args.profile)
    regions = discover_regions(sess, args.regions)

    end = dt.datetime.utcnow()
    start = end - dt.timedelta(days=args.window_days)

    results = []
    applied = 0

    for region in regions:
        elbv2 = sess.client("elbv2", region_name=region)
        cw = sess.client("cloudwatch", region_name=region)
        try:
            lbs = list_lbs(elbv2)
        except Exception as e:
            print(f"WARN region {region} list LBs failed: {e}", file=sys.stderr)
            continue
        for lb in lbs:
            lb_arn = lb.get("LoadBalancerArn")
            lb_name = lb.get("LoadBalancerName")
            lb_type = (lb.get("Type") or "").lower()  # application|network|gateway
            if lb_type == "gateway":
                # Gateway Load Balancer not considered in this script
                continue
            lb_dim = lb_cw_dimension_from_arn(lb_arn)
            if not lb_dim:
                continue

            if lb_type == "application":
                req_sum = cw_sum_metric(cw, ALB_NS, lb_dim, "RequestCount", start, end, args.period)
                bytes_sum = cw_sum_metric(cw, ALB_NS, lb_dim, "ProcessedBytes", start, end, args.period)
                is_idle = (req_sum <= args.min_requests) and (bytes_sum <= args.min_bytes)
                avg_flow = None
            else:
                avg_flow = cw_avg_metric(cw, NLB_NS, lb_dim, "ActiveFlowCount", start, end, args.period)
                bytes_sum = cw_sum_metric(cw, NLB_NS, lb_dim, "ProcessedBytes", start, end, args.period)
                is_idle = (avg_flow <= args.max_active_flows) and (bytes_sum <= args.min_bytes)
                req_sum = None

            tg_health = None
            tgs = None
            if args.check_target_health:
                try:
                    tgs = list_target_groups_for_lb(elbv2, lb_arn)
                except Exception:
                    tgs = []
                summary = {"healthy": 0, "unhealthy": 0, "initial": 0, "unused": 0, "draining": 0, "other": 0}
                for tg in tgs:
                    th = target_health_summary(elbv2, tg.get("TargetGroupArn"))
                    for state, count in th.items():
                        if state in summary:
                            summary[state] += count
                        else:
                            summary["other"] += count
                tg_health = summary

            rec = {
                "region": region,
                "lb_arn": lb_arn,
                "lb_name": lb_name,
                "type": lb_type,
                "scheme": lb.get("Scheme"),
                "vpc_id": lb.get("VpcId"),
                "security_groups": lb.get("SecurityGroups") if lb_type == "application" else None,
                "cw_dimension": lb_dim,
                "request_count_sum": req_sum,
                "active_flow_avg": avg_flow,
                "processed_bytes_sum": bytes_sum,
                "flagged_idle": is_idle,
                "target_health": tg_health,
                "tag_attempted": False,
                "tag_error": None,
            }

            if is_idle and args.apply_tag and applied < args.max_apply:
                err = apply_tag(elbv2, lb_arn, args.tag_key, args.tag_value)
                rec["tag_attempted"] = True
                rec["tag_error"] = err
                if err is None:
                    applied += 1

            if is_idle:
                results.append(rec)

    payload = {
        "regions": regions,
        "window_days": args.window_days,
        "min_requests": args.min_requests,
        "max_active_flows": args.max_active_flows,
        "min_bytes": args.min_bytes,
        "apply_tag": args.apply_tag,
        "applied": applied,
        "results": results,
    }

    if args.json:
        print(json.dumps(payload, indent=2))
        return 0

    if not results:
        print("No idle ALB/NLB found under current thresholds.")
        return 0

    header = ["Region", "Name", "Type", "ReqSum", "AvgFlow", "BytesSum", "Tagged"]
    rows = [header]
    for r in results:
        rows.append([
            r["region"], r["lb_name"], r["type"],
            ("-" if r.get("request_count_sum") is None else str(int(r.get("request_count_sum") or 0))),
            ("-" if r.get("active_flow_avg") is None else f"{r.get('active_flow_avg'):.2f}"),
            str(int(r.get("processed_bytes_sum") or 0)),
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
