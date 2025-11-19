#!/usr/bin/env python3
"""
aws-s3-unused-bucket-auditor.py

Purpose:
  Identify potentially unused / stale S3 buckets across the account using object count sampling
  and last modified age heuristics. Optionally tag candidates or delete EMPTY buckets (safe-only).

Signals (a bucket is flagged if ANY condition is met):
  - Empty bucket (0 objects) => candidate
  - Few objects (<= --max-object-count) AND latest object older than --min-days-since-mod (default 90)

Optional Additional Filters:
  - --name-filter substring match on bucket name
  - --exclude-prefix prefix to exclude matching bucket names (repeatable)
  - --required-tag Key=Value (repeatable; bucket must have ALL)

Actions (dry-run by default):
  - --apply-tag: merge tag set (adds tag key/value) with cap --max-tag
  - --apply-delete: delete empty buckets only with cap --max-delete (never deletes non-empty or versioned buckets)

Features:
  - Global bucket listing (S3 is global); region derived per bucket via GetBucketLocation
  - Object listing sampling (up to --list-max, default 2000 objects) to avoid huge scans
  - JSON output or human-readable table
  - CI exit (code 2) via --ci-exit-on-findings when findings exist

Safety:
  - Delete only attempted for buckets with object_count==0 AND versioning status not 'Enabled'. No force operations.
  - Tagging merges existing tags; existing tags preserved.

Permissions:
  - s3:ListAllMyBuckets, s3:GetBucketLocation, s3:GetBucketTagging, s3:PutBucketTagging
  - s3:ListBucket (to list objects), s3:DeleteBucket
  - s3:GetBucketVersioning

Examples:
  python aws-s3-unused-bucket-auditor.py --json
  python aws-s3-unused-bucket-auditor.py --min-days-since-mod 120 --max-object-count 25 --apply-tag --max-tag 40
  python aws-s3-unused-bucket-auditor.py --apply-delete --max-delete 5  # ONLY empty, non-versioned buckets

Exit Codes:
  0 success
  1 unexpected error
  2 findings (with --ci-exit-on-findings)
"""
import argparse
import boto3
import datetime as dt
import json
import sys
from typing import Any, Dict, List, Optional


def parse_args():
    p = argparse.ArgumentParser(description="Audit S3 buckets for potential unused/stale state (dry-run by default)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--name-filter", help="Substring match on bucket name")
    p.add_argument("--exclude-prefix", action="append", help="Exclude buckets starting with prefix (repeatable)")
    p.add_argument("--required-tag", action="append", help="Require Tag Key=Value (repeat)")
    p.add_argument("--min-days-since-mod", type=int, default=90, help="Min days since last object modification to deem stale (default: 90)")
    p.add_argument("--max-object-count", type=int, default=50, help="Max object count threshold for stale heuristic (default: 50)")
    p.add_argument("--list-max", type=int, default=2000, help="Max objects to list per bucket during sampling (default: 2000)")
    p.add_argument("--apply-tag", action="store_true", help="Apply tag to flagged buckets")
    p.add_argument("--tag-key", default="Cost:Review", help="Tag key (default: Cost:Review)")
    p.add_argument("--tag-value", default="s3-unused-candidate", help="Tag value (default: s3-unused-candidate)")
    p.add_argument("--max-tag", type=int, default=100, help="Max buckets to tag (default: 100)")
    p.add_argument("--apply-delete", action="store_true", help="Delete EMPTY, non-versioned buckets (safe-only)")
    p.add_argument("--max-delete", type=int, default=10, help="Max buckets to delete (default: 10)")
    p.add_argument("--ci-exit-on-findings", action="store_true", help="Exit code 2 if findings exist (CI mode)")
    p.add_argument("--json", action="store_true", help="JSON output")
    return p.parse_args()


def session(profile: Optional[str]):
    if profile:
        return boto3.Session(profile_name=profile)
    return boto3.Session()


def parse_required_tags(required: Optional[List[str]]) -> Dict[str, str]:
    out: Dict[str, str] = {}
    if not required:
        return out
    for r in required:
        if "=" not in r:
            continue
        k, v = r.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def list_buckets(s3) -> List[Dict[str, Any]]:
    try:
        resp = s3.list_buckets()
        return resp.get("Buckets", []) or []
    except Exception:
        return []


def bucket_region(s3, name: str) -> Optional[str]:
    try:
        resp = s3.get_bucket_location(Bucket=name)
        loc = resp.get("LocationConstraint")
        # us-east-1 is sometimes None
        return loc or "us-east-1"
    except Exception:
        return None


def bucket_versioning(s3, name: str) -> Optional[str]:
    try:
        resp = s3.get_bucket_versioning(Bucket=name)
        return resp.get("Status")  # 'Enabled' or 'Suspended' or None
    except Exception:
        return None


def bucket_tags(s3, name: str) -> Dict[str, str]:
    try:
        resp = s3.get_bucket_tagging(Bucket=name)
        return {t.get("Key"): t.get("Value") for t in resp.get("TagSet", [])}
    except Exception:
        return {}


def list_objects_sample(s3, name: str, max_items: int) -> Dict[str, Any]:
    """List up to max_items objects returning count and latest last_modified timestamp."""
    count = 0
    latest: Optional[dt.datetime] = None
    try:
        paginator = s3.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=name):
            for obj in page.get("Contents", []) or []:
                count += 1
                lm = obj.get("LastModified")
                if lm:
                    if lm.tzinfo:
                        lm = lm.astimezone(dt.timezone.utc).replace(tzinfo=None)
                    if not latest or lm > latest:
                        latest = lm
                if count >= max_items:
                    break
            if count >= max_items:
                break
    except Exception:
        pass
    return {"count_sample": count, "latest": latest, "truncated": count >= max_items}


def merge_and_tag(s3, name: str, key: str, value: str) -> Optional[str]:
    try:
        existing = bucket_tags(s3, name)
        existing[key] = value
        tagset = [{"Key": k, "Value": v} for k, v in existing.items()]
        s3.put_bucket_tagging(Bucket=name, Tagging={"TagSet": tagset})
        return None
    except Exception as e:
        return str(e)


def delete_bucket(s3, name: str) -> Optional[str]:
    try:
        s3.delete_bucket(Bucket=name)
        return None
    except Exception as e:
        return str(e)


def main():
    args = parse_args()
    sess = session(args.profile)
    s3 = sess.client("s3")
    required_tags = parse_required_tags(args.required_tag)

    now = dt.datetime.utcnow()
    buckets = list_buckets(s3)

    findings: List[Dict[str, Any]] = []
    tagged = 0
    deleted = 0

    for b in buckets:
        name = b.get("Name")
        if not name:
            continue
        if args.name_filter and args.name_filter not in name:
            continue
        if args.exclude_prefix:
            if any(name.startswith(p) for p in args.exclude_prefix):
                continue
        tags = bucket_tags(s3, name)
        if required_tags:
            if any(tags.get(k) != v for k, v in required_tags.items()):
                continue
        region = bucket_region(s3, name)
        ver_status = bucket_versioning(s3, name)

        sample = list_objects_sample(s3, name, args.list_max)
        obj_count = sample["count_sample"]  # sample count may be truncated
        latest = sample["latest"]
        truncated = sample["truncated"]

        days_since_mod = (now - latest).days if latest else None
        empty = obj_count == 0
        stale = (not empty) and (obj_count <= args.max_object_count) and (days_since_mod is not None) and (days_since_mod >= args.min_days_since_mod)

        flagged = empty or stale
        if not flagged:
            continue

        rec = {
            "bucket": name,
            "region": region,
            "versioning": ver_status,
            "object_count_sample": obj_count,
            "sample_truncated": truncated,
            "latest_object_ts": latest.isoformat() if latest else None,
            "days_since_latest": days_since_mod,
            "flag_empty": empty,
            "flag_stale": stale,
            "tag_attempted": False,
            "tag_error": None,
            "delete_attempted": False,
            "delete_error": None,
        }

        if flagged and args.apply_tag and tagged < args.max_tag:
            err = merge_and_tag(s3, name, args.tag_key, args.tag_value)
            rec["tag_attempted"] = True
            rec["tag_error"] = err
            if err is None:
                tagged += 1

        if empty and args.apply_delete and deleted < args.max_delete and ver_status != "Enabled":
            err = delete_bucket(s3, name)
            rec["delete_attempted"] = True
            rec["delete_error"] = err
            if err is None:
                deleted += 1

        findings.append(rec)

    payload = {
        "min_days_since_mod": args.min_days_since_mod,
        "max_object_count": args.max_object_count,
        "list_max": args.list_max,
        "apply_tag": args.apply_tag,
        "apply_delete": args.apply_delete,
        "tagged": tagged,
        "deleted": deleted,
        "results": findings,
    }

    if args.json:
        print(json.dumps(payload, indent=2))
        if args.ci_exit_on_findings and findings:
            return 2
        return 0

    if not findings:
        print("No unused or stale buckets found under current thresholds.")
        return 0

    header = ["Bucket", "Region", "Ver", "ObjSample", "Trunc", "DaysSince", "Empty", "Stale", "Tagged", "Deleted"]
    rows = [header]
    for r in findings:
        rows.append([
            r["bucket"], r.get("region") or "-", (r.get("versioning") or "-"), r["object_count_sample"],
            ("Y" if r["sample_truncated"] else "N"), (r["days_since_latest"] if r["days_since_latest"] is not None else "-"),
            ("Y" if r["flag_empty"] else "N"), ("Y" if r["flag_stale"] else "N"),
            ("Y" if r["tag_attempted"] and not r["tag_error"] else ("ERR" if r["tag_error"] else "N")),
            ("Y" if r["delete_attempted"] and not r["delete_error"] else ("ERR" if r["delete_error"] else "N")),
        ])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = '  '.join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print('  '.join('-' * w for w in widths))
        else:
            print(line)

    if not args.apply_tag and not args.apply_delete:
        print("\nDry-run. Use --apply-tag to tag or --apply-delete to delete EMPTY non-versioned buckets.")
    elif args.apply_delete:
        print("\nDelete attempted only for empty, non-versioned buckets.")

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
