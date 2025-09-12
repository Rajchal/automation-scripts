#!/usr/bin/env python3
"""
aws-lambda-unused-function-auditor.py

Purpose:
  Identify AWS Lambda functions that appear unused (low or zero Invocations)
  over a specified lookback window so they can be cleaned up or archived.

Heuristics:
  - Sum of Invocations metric over --days window <= --min-invocations (default 0)
  - Optional additional check: Errors + Throttles both zero (implied by no invocations but included for clarity)

Features:
  - Multi-region scan
  - Name substring filter (--name-filter)
  - Tag filter (--required-tag Key=Value) repeatable
  - JSON output option
  - Optional deletion (--delete) of flagged functions (dry-run default)
  - Limit deletions with --max-delete
  - Outputs last modified age

Permissions Required:
  - lambda:ListFunctions, lambda:ListTags, lambda:DeleteFunction
  - cloudwatch:GetMetricStatistics

Examples:
  python aws-lambda-unused-function-auditor.py --regions us-east-1 us-west-2 --days 14
  python aws-lambda-unused-function-auditor.py --min-invocations 5 --json
  python aws-lambda-unused-function-auditor.py --required-tag KeepAlive=true --delete

Exit Codes:
  0 success
  1 unexpected error
"""
import argparse
import boto3
import datetime as dt
import json
import sys
from typing import List, Dict, Any, Optional, Tuple

METRICS = ["Invocations", "Errors", "Throttles"]


def parse_args():
    p = argparse.ArgumentParser(description="Audit unused / low-use Lambda functions (dry-run)")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--days", type=int, default=14, help="Lookback window in days")
    p.add_argument("--period", type=int, default=300, help="Metric period seconds")
    p.add_argument("--min-invocations", type=int, default=0, help="Minimum total invocations to be considered used")
    p.add_argument("--name-filter", help="Substring filter on function name")
    p.add_argument("--required-tag", action="append", help="Key=Value tag filter to include (can repeat)")
    p.add_argument("--delete", action="store_true", help="Delete flagged functions")
    p.add_argument("--max-delete", type=int, default=50, help="Max deletions")
    p.add_argument("--json", action="store_true", help="JSON output")
    return p.parse_args()


def session(profile: Optional[str]):
    if profile:
        return boto3.Session(profile_name=profile)
    return boto3.Session()


def discover_regions(sess, explicit: Optional[List[str]]):
    if explicit:
        return explicit
    try:
        ec2 = sess.client("ec2")
        resp = ec2.describe_regions(AllRegions=False)
        return sorted(r["RegionName"] for r in resp["Regions"])
    except Exception:
        return ["us-east-1"]


def parse_tag_filters(required_tags: Optional[List[str]]) -> Dict[str, str]:
    out = {}
    if not required_tags:
        return out
    for t in required_tags:
        if "=" not in t:
            continue
        k, v = t.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def function_matches_tags(lambda_client, arn: str, needed: Dict[str, str]) -> bool:
    if not needed:
        return True
    try:
        tags = lambda_client.list_tags(Resource=arn).get("Tags", {})
    except Exception:
        return False
    for k, v in needed.items():
        if tags.get(k) != v:
            return False
    return True


def list_functions(lmbd):
    out = []
    token = None
    while True:
        kwargs = {"MaxItems": 50}
        if token:
            kwargs["Marker"] = token
        resp = lmbd.list_functions(**kwargs)
        out.extend(resp.get("Functions", []))
        token = resp.get("NextMarker")
        if not token:
            break
    return out


def fetch_metric(cw, fn_name: str, metric: str, start: dt.datetime, end: dt.datetime, period: int):
    try:
        resp = cw.get_metric_statistics(
            Namespace="AWS/Lambda",
            MetricName=metric,
            Dimensions=[{"Name": "FunctionName", "Value": fn_name}],
            StartTime=start,
            EndTime=end,
            Period=period,
            Statistics=["Sum"],
        )
    except Exception:
        return 0
    points = resp.get("Datapoints", [])
    total = 0
    for p in points:
        if "Sum" in p:
            total += p["Sum"]
    return total


def main():
    args = parse_args()
    sess = session(args.profile)
    regs = discover_regions(sess, args.regions)
    needed_tags = parse_tag_filters(args.required_tag)

    end = dt.datetime.utcnow()
    start = end - dt.timedelta(days=args.days)

    all_results = []
    delete_count = 0

    for region in regs:
        lmbd = sess.client("lambda", region_name=region)
        cw = sess.client("cloudwatch", region_name=region)
        try:
            functions = list_functions(lmbd)
        except Exception as e:
            print(f"WARN region {region} list functions failed: {e}", file=sys.stderr)
            continue
        for fn in functions:
            name = fn.get("FunctionName")
            if args.name_filter and args.name_filter not in name:
                continue
            arn = fn.get("FunctionArn")
            if not function_matches_tags(lmbd, arn, needed_tags):
                continue
            inv = fetch_metric(cw, name, "Invocations", start, end, args.period)
            if inv > args.min_invocations:
                continue
            errs = fetch_metric(cw, name, "Errors", start, end, args.period)
            throt = fetch_metric(cw, name, "Throttles", start, end, args.period)
            mod = fn.get("LastModified")  # str like '2025-09-12T12:34:56.789+0000'
            age_days = None
            try:
                # Remove timezone colon if present
                ts = mod.replace("+0000", "+00:00")
                mod_dt = dt.datetime.fromisoformat(ts)
                if mod_dt.tzinfo:
                    mod_dt = mod_dt.astimezone(dt.timezone.utc).replace(tzinfo=None)
                age_days = (end - mod_dt).days
            except Exception:
                pass
            status = "UNUSED"
            reasons = [f"Invocations={inv} <= {args.min_invocations}"]
            if errs == 0 and throt == 0:
                reasons.append("No Errors/Throttles (silent)")
            entry = {
                "region": region,
                "function": name,
                "arn": arn,
                "invocations": inv,
                "errors": errs,
                "throttles": throt,
                "age_days_since_last_modified": age_days,
                "status": status,
                "reasons": reasons,
                "delete_attempted": False,
                "delete_error": None,
            }
            if args.delete and delete_count < args.max_delete:
                try:
                    lmbd.delete_function(FunctionName=name)
                    entry["delete_attempted"] = True
                    delete_count += 1
                except Exception as e:
                    entry["delete_attempted"] = True
                    entry["delete_error"] = str(e)
            all_results.append(entry)

    if args.json:
        print(json.dumps({
            "regions": regs,
            "lookback_days": args.days,
            "min_invocations": args.min_invocations,
            "delete": args.delete,
            "results": all_results,
        }, indent=2))
        return 0

    if not all_results:
        print("No unused Lambda functions detected.")
        return 0

    header = ["Region", "Function", "Inv", "Errors", "Thr", "AgeMod(d)", "Deleted"]
    rows = [header]
    for r in all_results:
        rows.append([
            r["region"], r["function"], r["invocations"], r["errors"], r["throttles"], r.get("age_days_since_last_modified"),
            "Y" if r["delete_attempted"] and not r["delete_error"] else ("ERR" if r["delete_error"] else "N")
        ])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = "  ".join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print("  ".join("-" * w for w in widths))
        else:
            print(line)
    if not args.delete:
        print("\nDry-run only. Use --delete to remove unused functions.")
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
