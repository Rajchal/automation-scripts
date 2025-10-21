#!/usr/bin/env python3
"""
aws-dynamodb-usage-auditor.py

Purpose:
  Analyze DynamoDB table usage to identify under-utilized tables (both PROVISIONED and
  PAY_PER_REQUEST) and flag candidates for downsizing or removal.

Features:
  - Multi-region scan (default: all enabled)
  - CloudWatch metric window (default 14 days)
  - For PROVISIONED tables: compute read/write capacity utilization as percentage of ProvisionedThroughput
  - For PAY_PER_REQUEST: flag tables with very low activity (reads+writes below threshold)
  - Filters: --name-filter, --required-tag Key=Value (repeatable)
  - Actions: --apply-tag to mark candidates for review (dry-run by default)
  - Safety cap: --max-apply
  - JSON or human-readable output

Permissions:
  - dynamodb:ListTables, dynamodb:DescribeTable, cloudwatch:GetMetricStatistics, dynamodb:ListTagsOfResource, dynamodb:TagResource

Examples:
  python aws-dynamodb-usage-auditor.py --window-days 14 --min-util-percent 10 --json
  python aws-dynamodb-usage-auditor.py --name-filter sessions --apply-tag --max-apply 20

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


CW_NS = "AWS/DynamoDB"


def parse_args():
    p = argparse.ArgumentParser(description="Audit DynamoDB table usage and flag under-utilized tables")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all enabled)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--window-days", type=int, default=14, help="CloudWatch lookback window in days (default: 14)")
    p.add_argument("--period", type=int, default=3600, help="Metric period in seconds (default: 3600)")
    p.add_argument("--min-util-percent", type=float, default=10.0, help="Minimum average percent utilization for PROVISIONED tables (default: 10.0)")
    p.add_argument("--paylow-threshold", type=int, default=100, help="For PAY_PER_REQUEST, flag if reads+writes over window < threshold (default: 100)")
    p.add_argument("--name-filter", help="Substring filter on table name")
    p.add_argument("--required-tag", action="append", help="Require Tag Key=Value (repeat)")
    p.add_argument("--apply-tag", action="store_true", help="Tag flagged tables for review")
    p.add_argument("--tag-key", default="Cost:Review", help="Tag key (default: Cost:Review)")
    p.add_argument("--tag-value", default="dynamo-unused-candidate", help="Tag value (default: dynamo-unused-candidate)")
    p.add_argument("--max-apply", type=int, default=50, help="Max tables to tag (default: 50)")
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


def cw_sum_metric(cw, table_name: str, metric_name: str, start: dt.datetime, end: dt.datetime, period: int) -> float:
    try:
        resp = cw.get_metric_statistics(
            Namespace=CW_NS,
            MetricName=metric_name,
            Dimensions=[{"Name": "TableName", "Value": table_name}],
            StartTime=start,
            EndTime=end,
            Period=period,
            Statistics=["Sum"],
        )
        return float(sum(p.get("Sum", 0.0) for p in resp.get("Datapoints", [])))
    except Exception:
        return 0.0


def cw_avg_metric(cw, table_name: str, metric_name: str, start: dt.datetime, end: dt.datetime, period: int) -> float:
    try:
        resp = cw.get_metric_statistics(
            Namespace=CW_NS,
            MetricName=metric_name,
            Dimensions=[{"Name": "TableName", "Value": table_name}],
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


def tag_table(dynamodb, table_arn: str, key: str, value: str) -> Optional[str]:
    try:
        dynamodb.tag_resource(ResourceArn=table_arn, Tags=[{"Key": key, "Value": value}])
        return None
    except Exception as e:
        return str(e)


def list_tags(dynamodb, table_arn: str) -> Dict[str, str]:
    try:
        resp = dynamodb.list_tags_of_resource(ResourceArn=table_arn)
        return {t.get("Key"): t.get("Value") for t in resp.get("Tags", [])}
    except Exception:
        return {}


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
        dd = sess.client("dynamodb", region_name=region)
        cw = sess.client("cloudwatch", region_name=region)
        try:
            tables_resp = dd.list_tables()
            tables = tables_resp.get("TableNames", [])
        except Exception as e:
            print(f"WARN region {region} list tables failed: {e}", file=sys.stderr)
            continue

        for t in tables:
            if args.name_filter and args.name_filter not in t:
                continue
            try:
                desc = dd.describe_table(TableName=t)
                table_arn = desc.get("Table", {}).get("TableArn")
                billing = desc.get("Table", {}).get("BillingModeSummary", {}).get("BillingMode")
                provisioned = desc.get("Table", {}).get("ProvisionedThroughput", {})
                read_units = provisioned.get("ReadCapacityUnits") or 0
                write_units = provisioned.get("WriteCapacityUnits") or 0
            except Exception:
                continue

            tags = list_tags(dd, table_arn) if table_arn else {}
            if needed_tags:
                ok = True
                for k, v in needed_tags.items():
                    if tags.get(k) != v:
                        ok = False
                        break
                if not ok:
                    continue

            # CloudWatch metrics
            consumed_read = cw_sum_metric(cw, t, "ConsumedReadCapacityUnits", start, end, args.period)
            consumed_write = cw_sum_metric(cw, t, "ConsumedWriteCapacityUnits", start, end, args.period)

            # For PROVISIONED, compute average utilization percent over window
            read_util_pct = None
            write_util_pct = None
            if billing == "PROVISIONED":
                # average provisioned per period: provisioned_units * (window_seconds / period) aggregated
                window_seconds = (end - start).total_seconds()
                periods = max(1, int(window_seconds // args.period))
                avg_read_provisioned = (read_units * args.period)  # units per period
                avg_write_provisioned = (write_units * args.period)
                # consumed_read is sum over window; convert to per-period average
                avg_consumed_read_per_period = consumed_read / max(1, periods)
                avg_consumed_write_per_period = consumed_write / max(1, periods)
                # utilization percent
                read_util_pct = (avg_consumed_read_per_period / avg_read_provisioned * 100.0) if avg_read_provisioned > 0 else 0.0
                write_util_pct = (avg_consumed_write_per_period / avg_write_provisioned * 100.0) if avg_write_provisioned > 0 else 0.0

            # PAY_PER_REQUEST (on-demand): flag if total ops over window is below threshold
            pay_ops = None
            pay_flag = False
            if billing == "PAY_PER_REQUEST":
                total_ops = int(consumed_read + consumed_write)
                pay_ops = total_ops
                if total_ops < args.paylow_threshold:
                    pay_flag = True

            flagged = False
            reasons = []
            if billing == "PROVISIONED":
                if (read_util_pct is not None and read_util_pct < args.min_util_percent) or (write_util_pct is not None and write_util_pct < args.min_util_percent):
                    flagged = True
                    reasons.append(f"low-util r:{read_util_pct:.1f}% w:{write_util_pct:.1f}%")
            elif billing == "PAY_PER_REQUEST":
                if pay_flag:
                    flagged = True
                    reasons.append(f"low-ops total:{pay_ops}")

            rec = {
                "region": region,
                "table": t,
                "table_arn": table_arn,
                "billing_mode": billing,
                "read_units": read_units,
                "write_units": write_units,
                "consumed_read": consumed_read,
                "consumed_write": consumed_write,
                "read_util_pct": read_util_pct,
                "write_util_pct": write_util_pct,
                "pay_ops": pay_ops,
                "flagged": flagged,
                "reasons": reasons,
                "tag_attempted": False,
                "tag_error": None,
            }

            if flagged and args.apply_tag and applied < args.max_apply and table_arn:
                err = tag_table(dd, table_arn, args.tag_key, args.tag_value)
                rec["tag_attempted"] = True
                rec["tag_error"] = err
                if err is None:
                    applied += 1

            if flagged:
                results.append(rec)

    payload = {
        "regions": regions,
        "window_days": args.window_days,
        "min_util_percent": args.min_util_percent,
        "paylow_threshold": args.paylow_threshold,
        "apply_tag": args.apply_tag,
        "applied": applied,
        "results": results,
    }

    if args.json:
        print(json.dumps(payload, indent=2))
        return 0

    if not results:
        print("No under-utilized DynamoDB tables found under current thresholds.")
        return 0

    header = ["Region", "Table", "Billing", "ReadUtil%", "WriteUtil%", "Ops", "Tagged"]
    rows = [header]
    for r in results:
        rows.append([
            r["region"], r["table"], r["billing_mode"] or "-",
            ("-" if r.get("read_util_pct") is None else f"{r['read_util_pct']:.1f}%"),
            ("-" if r.get("write_util_pct") is None else f"{r['write_util_pct']:.1f}%"),
            (r.get("pay_ops") if r.get("pay_ops") is not None else "-"),
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
