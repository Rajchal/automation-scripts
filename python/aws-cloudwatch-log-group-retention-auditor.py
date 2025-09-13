#!/usr/bin/env python3
"""
aws-cloudwatch-log-group-retention-auditor.py

Purpose:
  Audit CloudWatch Log Groups for missing (infinite) or excessive retention and
  optionally apply a consistent retention policy.

Classification:
  - MISSING: No retention set (infinite) -> candidate to apply --target-retention-days
  - EXCESS: RetentionInDays > --max-retention-days (if provided)

Features:
  - Multi-region scan
  - Name filter substring (--name-filter)
  - Tag filter (--required-tag Key=Value) repeatable
  - Optional --apply to set retention on MISSING or EXCESS groups to --target-retention-days
  - JSON output option
  - Limit changes with --max-apply

Permissions Required:
  - logs:DescribeLogGroups, logs:ListTagsLogGroup, logs:PutRetentionPolicy

Examples:
  python aws-cloudwatch-log-group-retention-auditor.py --regions us-east-1 us-west-2 --target-retention-days 30
  python aws-cloudwatch-log-group-retention-auditor.py --max-retention-days 365 --target-retention-days 90 --apply

Exit Codes:
  0 success
  1 error
"""
import argparse
import boto3
import json
import sys
from typing import List, Dict, Any, Optional


def parse_args():
    p = argparse.ArgumentParser(description="Audit / apply CloudWatch log group retention")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--name-filter", help="Substring filter on log group name")
    p.add_argument("--required-tag", action="append", help="Tag filter Key=Value (repeat)")
    p.add_argument("--max-retention-days", type=int, help="Max allowed retention; above classified EXCESS")
    p.add_argument("--target-retention-days", type=int, default=30, help="Retention to apply when fixing (default 30)")
    p.add_argument("--apply", action="store_true", help="Apply retention policy to flagged groups")
    p.add_argument("--max-apply", type=int, default=100, help="Max log groups to update")
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


def log_group_tags(client, name: str):
    try:
        return client.list_tags_log_group(logGroupName=name).get("tags", {})
    except Exception:
        return {}


def matches_tags(client, name: str, needed: Dict[str, str]):
    if not needed:
        return True
    tags = log_group_tags(client, name)
    for k, v in needed.items():
        if tags.get(k) != v:
            return False
    return True


def list_log_groups(logs):
    out = []
    token = None
    while True:
        kwargs = {"limit": 50}
        if token:
            kwargs["nextToken"] = token
        resp = logs.describe_log_groups(**kwargs)
        out.extend(resp.get("logGroups", []))
        token = resp.get("nextToken")
        if not token:
            break
    return out


def apply_retention(logs, name: str, days: int) -> Optional[str]:
    try:
        logs.put_retention_policy(logGroupName=name, retentionInDays=days)
        return None
    except Exception as e:
        return str(e)


def main():
    args = parse_args()
    sess = session(args.profile)
    regs = discover_regions(sess, args.regions)
    needed_tags = parse_tag_filters(args.required_tag)

    results = []
    apply_count = 0

    for region in regs:
        logs = sess.client("logs", region_name=region)
        try:
            groups = list_log_groups(logs)
        except Exception as e:
            print(f"WARN region {region} list log groups failed: {e}", file=sys.stderr)
            continue
        for g in groups:
            name = g.get("logGroupName")
            if args.name_filter and args.name_filter not in name:
                continue
            if not matches_tags(logs, name, needed_tags):
                continue
            retention = g.get("retentionInDays")
            status = None
            reasons = []
            if retention is None:
                status = "MISSING"
                reasons.append("No retention set (infinite)")
            elif args.max_retention_days and retention > args.max_retention_days:
                status = "EXCESS"
                reasons.append(f"Retention {retention}d > max {args.max_retention_days}d")
            if not status:
                continue
            rec = {
                "region": region,
                "name": name,
                "current_retention": retention,
                "status": status,
                "reasons": reasons,
                "apply_attempted": False,
                "apply_error": None,
                "new_retention": None,
            }
            if args.apply and apply_count < args.max_apply:
                err = apply_retention(logs, name, args.target_retention_days)
                rec["apply_attempted"] = True
                rec["apply_error"] = err
                rec["new_retention"] = None if err else args.target_retention_days
                apply_count += 1
            results.append(rec)

    if args.json:
        print(json.dumps({
            "regions": regs,
            "target_retention_days": args.target_retention_days,
            "max_retention_days": args.max_retention_days,
            "apply": args.apply,
            "results": results,
        }, indent=2))
        return 0

    if not results:
        print("No log groups with missing or excessive retention found.")
        return 0

    header = ["Region", "LogGroup", "Current", "Status", "Applied"]
    rows = [header]
    for r in results:
        rows.append([
            r["region"], r["name"], r["current_retention"], r["status"],
            ("Y" if r["apply_attempted"] and not r["apply_error"] else ("ERR" if r["apply_error"] else "N"))
        ])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = "  ".join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print("  ".join("-" * w for w in widths))
        else:
            print(line)
    if not args.apply:
        print("\nDry-run only. Use --apply to set retention.")
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
