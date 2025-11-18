#!/usr/bin/env python3
"""
aws-ec2-idle-instance-auditor.py

Purpose:
  Identify potentially idle EC2 instances (running) across regions using CloudWatch metrics.
  Optionally tag or stop flagged instances (dry-run by default; stopping requires explicit flag & safety cap).

Idle Heuristic (all must be satisfied):
  - Average CPUUtilization <= --max-cpu-avg (default 3.0)
  - Sum(NetworkIn + NetworkOut) over window <= --max-network-mb (default 50 MB)
  - Instance is in 'running' state

Features:
  - Multi-region scan (discovers enabled regions unless --regions specified)
  - Configurable lookback window (--window-days, default 7) & metric period (--period, default 3600s)
  - Filters: --name-filter matches Name tag substring; --exclude-tag Key=Value (repeatable)
  - Actions:
      * --apply-tag (safe metadata) with --tag-key/--tag-value & --max-tag
      * --apply-stop to stop instances (requires --confirm-stop and subject to --max-stop)
  - Output: human-readable table or --json

Safety Notes:
  - No action taken unless --apply-tag or --apply-stop provided.
  - Stopping instances can impact services; use small --max-stop first and consider --dry-strict in CI.
  - Instances with missing metrics are treated as NON-idle (conservative) unless --treat-missing-metrics-idle.

Permissions Required:
  - ec2:DescribeInstances, ec2:StopInstances, ec2:DescribeTags (covered by DescribeInstances), ec2:CreateTags
  - cloudwatch:GetMetricStatistics
  - ec2:DescribeRegions

Examples:
  python aws-ec2-idle-instance-auditor.py --regions us-east-1 us-west-2 --json
  python aws-ec2-idle-instance-auditor.py --max-cpu-avg 2 --max-network-mb 20 --apply-tag --max-tag 30
  python aws-ec2-idle-instance-auditor.py --apply-stop --confirm-stop --max-stop 2 --name-filter staging

Exit Codes:
  0 success
  1 unexpected error
  2 findings (CI mode with --ci-exit-on-findings)
"""
import argparse
import boto3
import datetime as dt
import json
import sys
from typing import Any, Dict, List, Optional

CW_NS = "AWS/EC2"


def parse_args():
    p = argparse.ArgumentParser(description="Audit idle EC2 instances (dry-run by default)")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all enabled)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--window-days", type=int, default=7, help="Metric lookback window in days (default: 7)")
    p.add_argument("--period", type=int, default=3600, help="Metric period seconds (default: 3600)")
    p.add_argument("--max-cpu-avg", type=float, default=3.0, help="Max average CPUUtilization to be idle (default: 3.0)")
    p.add_argument("--max-network-mb", type=float, default=50.0, help="Max combined NetworkIn+Out (MB) to be idle (default: 50)")
    p.add_argument("--name-filter", help="Substring match on Name tag")
    p.add_argument("--exclude-tag", action="append", help="Exclude instances with Tag Key=Value (repeat)")
    p.add_argument("--treat-missing-metrics-idle", action="store_true", help="If metrics absent treat as idle (default: treat active)")
    p.add_argument("--apply-tag", action="store_true", help="Apply tag to flagged instances")
    p.add_argument("--tag-key", default="Cost:Review", help="Tag key (default: Cost:Review)")
    p.add_argument("--tag-value", default="ec2-idle-candidate", help="Tag value (default: ec2-idle-candidate)")
    p.add_argument("--max-tag", type=int, default=100, help="Max instances to tag (default: 100)")
    p.add_argument("--apply-stop", action="store_true", help="Stop flagged instances (requires --confirm-stop)")
    p.add_argument("--confirm-stop", action="store_true", help="Explicit confirmation to allow stopping")
    p.add_argument("--max-stop", type=int, default=5, help="Max instances to stop (default: 5)")
    p.add_argument("--ci-exit-on-findings", action="store_true", help="Exit code 2 if any idle instances flagged (CI integration)")
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


def parse_exclude_tags(ex: Optional[List[str]]) -> Dict[str, str]:
    out: Dict[str, str] = {}
    if not ex:
        return out
    for item in ex:
        if "=" not in item:
            continue
        k, v = item.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def instance_name(tags: Optional[List[Dict[str, Any]]]) -> Optional[str]:
    if not tags:
        return None
    for t in tags:
        if t.get("Key") == "Name":
            return t.get("Value")
    return None


def cw_avg_metric(cw, instance_id: str, metric: str, start: dt.datetime, end: dt.datetime, period: int) -> Optional[float]:
    try:
        resp = cw.get_metric_statistics(
            Namespace=CW_NS,
            MetricName=metric,
            Dimensions=[{"Name": "InstanceId", "Value": instance_id}],
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


def cw_sum_metric(cw, instance_id: str, metric: str, start: dt.datetime, end: dt.datetime, period: int) -> Optional[float]:
    try:
        resp = cw.get_metric_statistics(
            Namespace=CW_NS,
            MetricName=metric,
            Dimensions=[{"Name": "InstanceId", "Value": instance_id}],
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


def tag_instance(ec2, instance_id: str, key: str, value: str) -> Optional[str]:
    try:
        ec2.create_tags(Resources=[instance_id], Tags=[{"Key": key, "Value": value}])
        return None
    except Exception as e:
        return str(e)


def stop_instances(ec2, ids: List[str]) -> Optional[str]:
    try:
        ec2.stop_instances(InstanceIds=ids)
        return None
    except Exception as e:
        return str(e)


def main():
    args = parse_args()
    sess = session(args.profile)
    regions = discover_regions(sess, args.regions)
    exclude_tags = parse_exclude_tags(args.exclude_tag)

    end = dt.datetime.utcnow()
    start = end - dt.timedelta(days=args.window_days)

    results: List[Dict[str, Any]] = []
    tagged = 0
    stopped = 0
    to_stop: List[str] = []

    for region in regions:
        ec2 = sess.client("ec2", region_name=region)
        cw = sess.client("cloudwatch", region_name=region)
        paginator = ec2.get_paginator("describe_instances")
        try:
            for page in paginator.paginate():
                for reservation in page.get("Reservations", []):
                    for inst in reservation.get("Instances", []):
                        state = inst.get("State", {}).get("Name")
                        if state != "running":
                            continue
                        iid = inst.get("InstanceId")
                        tags = inst.get("Tags") or []
                        name = instance_name(tags)
                        if args.name_filter and (args.name_filter not in (name or "") and args.name_filter not in iid):
                            continue
                        excluded = False
                        for k, v in exclude_tags.items():
                            for t in tags:
                                if t.get("Key") == k and t.get("Value") == v:
                                    excluded = True
                                    break
                            if excluded:
                                break
                        if excluded:
                            continue

                        cpu_avg = cw_avg_metric(cw, iid, "CPUUtilization", start, end, args.period)
                        net_in = cw_sum_metric(cw, iid, "NetworkIn", start, end, args.period)
                        net_out = cw_sum_metric(cw, iid, "NetworkOut", start, end, args.period)

                        metrics_missing = (cpu_avg is None) or (net_in is None) or (net_out is None)
                        if metrics_missing and not args.treat-missing-metrics-idle:
                            continue  # conservative; treat active

                        cpu_v = cpu_avg if cpu_avg is not None else 0.0
                        net_total_bytes = (net_in or 0.0) + (net_out or 0.0)
                        net_total_mb = net_total_bytes / (1024 * 1024)

                        idle = (cpu_v <= args.max_cpu_avg) and (net_total_mb <= args.max_network_mb)
                        if not idle:
                            continue

                        rec = {
                            "region": region,
                            "instance_id": iid,
                            "name": name,
                            "cpu_avg": cpu_v,
                            "network_mb": net_total_mb,
                            "metrics_missing": metrics_missing,
                            "tag_attempted": False,
                            "tag_error": None,
                            "stop_attempted": False,
                            "stop_error": None,
                        }

                        if idle and args.apply_tag and tagged < args.max_tag:
                            err = tag_instance(ec2, iid, args.tag_key, args.tag_value)
                            rec["tag_attempted"] = True
                            rec["tag_error"] = err
                            if err is None:
                                tagged += 1

                        if idle and args.apply_stop and args.confirm_stop and stopped < args.max_stop:
                            to_stop.append(iid)
                            rec["stop_attempted"] = True

                        results.append(rec)
        except Exception as e:
            print(f"WARN region {region} describe_instances failed: {e}", file=sys.stderr)
            continue

        # Perform stop in region batches (after enumeration) respecting cap
        if to_stop and args.apply_stop and args.confirm_stop and stopped < args.max_stop:
            batch = to_stop[: (args.max_stop - stopped)]
            err = stop_instances(ec2, batch)
            if err:
                for r in results:
                    if r["instance_id"] in batch and r["stop_attempted"]:
                        r["stop_error"] = err
            else:
                stopped += len(batch)
            to_stop = []  # reset per region

    payload = {
        "regions": regions,
        "window_days": args.window_days,
        "max_cpu_avg": args.max_cpu_avg,
        "max_network_mb": args.max_network_mb,
        "apply_tag": args.apply_tag,
        "apply_stop": args.apply_stop,
        "tagged": tagged,
        "stopped": stopped,
        "results": results,
    }

    if args.json:
        print(json.dumps(payload, indent=2))
        if args.ci_exit_on_findings and results:
            return 2
        return 0

    if not results:
        print("No idle EC2 instances found under current thresholds.")
        return 0

    header = ["Region", "InstanceId", "Name", "CPUAvg", "NetMB", "Tagged", "Stopped", "MissingMetrics"]
    rows = [header]
    for r in results:
        rows.append([
            r["region"], r["instance_id"], r.get("name") or "-", f"{r['cpu_avg']:.2f}", f"{r['network_mb']:.1f}",
            ("Y" if r["tag_attempted"] and not r["tag_error"] else ("ERR" if r["tag_error"] else "N")),
            ("Y" if r["stop_attempted"] and not r["stop_error"] else ("ERR" if r["stop_error"] else "N")),
            ("Y" if r["metrics_missing"] else "N"),
        ])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = '  '.join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print('  '.join('-' * w for w in widths))
        else:
            print(line)

    if not args.apply_tag and not (args.apply_stop and args.confirm_stop):
        print("\nDry-run. Use --apply-tag or --apply-stop --confirm-stop to take action.")
    elif args.apply_stop and not args.confirm_stop:
        print("\nStop requested but --confirm-stop missing; no instances stopped.")

    if args.ci_exit_on_findings:
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
