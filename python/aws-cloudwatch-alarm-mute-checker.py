#!/usr/bin/env python3
"""
aws-cloudwatch-alarm-mute-checker.py

Purpose:
  Detect potentially "muted" or ineffective Amazon CloudWatch alarms so you
  can clean up or fix monitoring blind spots.

Flags problems:
  - Alarms in INSUFFICIENT_DATA for > --stale-days (default 3).
  - Alarms with no OK/ALARM actions (missing SNS / AutoScaling / etc.).
  - Alarms in OK for excessively long period ( > --long-ok-days ) while metric stream has no recent data.
  - Alarms with actions disabled.

Heuristics:
  - For long OK detection, we sample Recent Datapoints for the metric; if zero
    datapoints over lookback, alarm might be stale.
  - Uses GetMetricStatistics (simple) for a quick existence check only.

Safe: Read-only; no modifications.

Output:
  - Human table or JSON (--json) summarizing flagged alarms and reasons.

Requirements:
  - boto3
  - cloudwatch:DescribeAlarms, cloudwatch:GetMetricStatistics

Examples:
  python aws-cloudwatch-alarm-mute-checker.py --regions us-east-1 us-west-2 --json
  python aws-cloudwatch-alarm-mute-checker.py --profile prod --stale-days 5 --long-ok-days 30

Exit Codes:
  0 success
  1 unexpected error
"""
import argparse
import boto3
import datetime as dt
import json
import sys
from typing import List, Dict, Any, Optional


def parse_args():
    p = argparse.ArgumentParser(description="Detect stale / muted CloudWatch alarms")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all account regions)")
    p.add_argument("--profile", help="AWS profile")
    p.add_argument("--stale-days", type=int, default=3, help="Alarms in INSUFFICIENT_DATA longer than this are flagged")
    p.add_argument("--long-ok-days", type=int, default=21, help="Alarms OK this long but with no recent datapoints flagged")
    p.add_argument("--metric-lookback-hours", type=int, default=24, help="Window to check for recent datapoints for long OK alarms")
    p.add_argument("--json", action="store_true", help="JSON output")
    p.add_argument("--name-filter", help="Substring filter on alarm name")
    p.add_argument("--namespace-filter", help="Substring filter on metric namespace")
    return p.parse_args()


def session(profile: Optional[str]):
    if profile:
        return boto3.Session(profile_name=profile)
    return boto3.Session()


def regions(sess, explicit):
    if explicit:
        return explicit
    try:
        ec2 = sess.client("ec2")
        r = ec2.describe_regions(AllRegions=False)
        return sorted([x["RegionName"] for x in r["Regions"]])
    except Exception:
        return ["us-east-1"]


def list_alarms(cw):
    out = []
    token = None
    while True:
        kwargs = {"MaxRecords": 100}
        if token:
            kwargs["NextToken"] = token
        resp = cw.describe_alarms(**kwargs)
        out.extend(resp.get("MetricAlarms", []))
        token = resp.get("NextToken")
        if not token:
            break
    return out


def has_recent_datapoint(cw, alarm, lookback_hours: int) -> bool:
    metric = alarm.get("MetricName")
    ns = alarm.get("Namespace")
    dims = alarm.get("Dimensions", [])
    if not metric or not ns:
        return False
    end = dt.datetime.utcnow()
    start = end - dt.timedelta(hours=lookback_hours)
    try:
        resp = cw.get_metric_statistics(
            Namespace=ns,
            MetricName=metric,
            Dimensions=dims,
            StartTime=start,
            EndTime=end,
            Period=300,
            Statistics=["SampleCount"],
        )
    except Exception:
        return False
    dp = resp.get("Datapoints", [])
    return len(dp) > 0


def classify(alarm, now: dt.datetime, args, cw) -> List[str]:
    reasons = []
    state = alarm.get("StateValue")
    updated = alarm.get("StateUpdatedTimestamp")
    if isinstance(updated, str):
        try:
            updated = dt.datetime.fromisoformat(updated.replace("Z", "+00:00"))
        except Exception:
            updated = None
    if updated and isinstance(updated, dt.datetime) and updated.tzinfo:
        updated = updated.astimezone(dt.timezone.utc).replace(tzinfo=None)

    if state == "INSUFFICIENT_DATA" and updated:
        if now - updated > dt.timedelta(days=args.stale_days):
            reasons.append(f"INSUFFICIENT_DATA > {args.stale_days}d")

    if not alarm.get("OKActions") and not alarm.get("AlarmActions"):
        reasons.append("No OK/ALARM actions configured")

    if alarm.get("ActionsEnabled") is False:
        reasons.append("Actions disabled")

    if state == "OK" and updated and (now - updated > dt.timedelta(days=args.long_ok_days)):
        if not has_recent_datapoint(cw, alarm, args.metric_lookback_hours):
            reasons.append(f"OK > {args.long_ok_days}d & no recent datapoints")

    return reasons


def main():
    args = parse_args()
    sess = session(args.profile)
    regs = regions(sess, args.regions)
    now = dt.datetime.utcnow()
    flagged = []

    for region in regs:
        cw = sess.client("cloudwatch", region_name=region)
        try:
            alarms = list_alarms(cw)
        except Exception as e:
            print(f"WARN region {region} describe_alarms failed: {e}", file=sys.stderr)
            continue
        for a in alarms:
            name = a.get("AlarmName")
            metric_ns = a.get("Namespace") or a.get("Metrics", [{}])[0].get("Namespace")
            if args.name_filter and args.name_filter not in name:
                continue
            if args.namespace_filter and metric_ns and args.namespace_filter not in metric_ns:
                continue
            reasons = classify(a, now, args, cw)
            if reasons:
                flagged.append({
                    "region": region,
                    "name": name,
                    "state": a.get("StateValue"),
                    "updated": str(a.get("StateUpdatedTimestamp")),
                    "metric": a.get("MetricName"),
                    "namespace": metric_ns,
                    "reasons": reasons,
                })

    if args.json:
        print(json.dumps({
            "regions": regs,
            "stale_days": args.stale_days,
            "long_ok_days": args.long_ok_days,
            "metric_lookback_hours": args.metric_lookback_hours,
            "flagged": flagged,
        }, indent=2))
        return 0

    if not flagged:
        print("No muted / stale alarms detected under current heuristics.")
        return 0

    header = ["Region", "Name", "State", "Updated", "Metric", "Namespace", "Reasons"]
    rows = [header]
    for f in flagged:
        rows.append([
            f["region"], f["name"], f["state"], f["updated"], f.get("metric") or "-", f.get("namespace") or "-", "; ".join(f["reasons"])
        ])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = "  ".join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print("  ".join("-" * w for w in widths))
        else:
            print(line)

    print("\nSuggestions: Review flagged alarms; add actions, fix metrics, or delete obsolete ones.")
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
