#!/usr/bin/env python3
"""
aws-secretsmanager-stale-secret-auditor.py

Purpose:
  Audit AWS Secrets Manager for secrets that appear stale (not accessed recently) or not rotated
  recently. Optionally tag such secrets for review or schedule deletion with a recovery window.

Features:
  - Multi-region scan (default: all enabled regions)
  - Filters:
      * --name-filter substring on secret name
      * --required-tag Key=Value (repeatable)
  - Findings criteria (any that apply will flag):
      * --stale-days N: LastAccessedDate older than N days or missing
      * --rotation-max-days N: LastRotatedDate older than N days (or rotation disabled)
  - Actions (dry-run by default):
      * --apply-tag with --tag-key/--tag-value and --max-apply cap
      * --schedule-delete with --recovery-days (default 30) and --max-apply cap
  - Output: human-readable table or --json for CI

Notes & Safety:
  - Scheduling deletion uses a recovery window; secret can be restored before final deletion.
  - LastAccessedDate may be None if never accessed or not recorded; treat as stale when --stale-days is set.

Permissions:
  - secretsmanager:ListSecrets, secretsmanager:DescribeSecret, secretsmanager:ListSecretVersionIds,
    secretsmanager:TagResource, secretsmanager:UntagResource, secretsmanager:DeleteSecret
  - ec2:DescribeRegions (for region discovery)

Examples:
  python aws-secretsmanager-stale-secret-auditor.py --stale-days 90 --rotation-max-days 180 --json
  python aws-secretsmanager-stale-secret-auditor.py --name-filter app/ --apply-tag --max-apply 20
  python aws-secretsmanager-stale-secret-auditor.py --stale-days 120 --schedule-delete --recovery-days 30 --max-apply 5

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


def parse_args():
    p = argparse.ArgumentParser(description="Audit Secrets Manager for stale/unrotated secrets (dry-run by default)")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all enabled)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--name-filter", help="Substring filter on secret name")
    p.add_argument("--required-tag", action="append", help="Require Tag Key=Value to include (repeat)")
    p.add_argument("--stale-days", type=int, help="Flag if LastAccessedDate older than N days or missing")
    p.add_argument("--rotation-max-days", type=int, help="Flag if LastRotatedDate older than N days or rotation disabled")
    p.add_argument("--apply-tag", action="store_true", help="Tag flagged secrets for review")
    p.add_argument("--tag-key", default="Cost:Review", help="Tag key (default: Cost:Review)")
    p.add_argument("--tag-value", default="stale-secret", help="Tag value (default: stale-secret)")
    p.add_argument("--schedule-delete", action="store_true", help="Schedule deletion for flagged secrets (with recovery window)")
    p.add_argument("--recovery-days", type=int, default=30, help="Recovery window days for scheduled deletion (default: 30)")
    p.add_argument("--max-apply", type=int, default=50, help="Max resources to tag/delete (default: 50)")
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


def list_secrets(sm) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    token = None
    while True:
        kwargs: Dict[str, Any] = {}
        if token:
            kwargs["NextToken"] = token
        resp = sm.list_secrets(**kwargs)
        out.extend(resp.get("SecretList", []) or [])
        token = resp.get("NextToken")
        if not token:
            break
    return out


def tag_secret(sm, arn: str, key: str, value: str) -> Optional[str]:
    try:
        sm.tag_resource(SecretId=arn, Tags=[{"Key": key, "Value": value}])
        return None
    except Exception as e:
        return str(e)


def schedule_delete(sm, arn: str, recovery_days: int) -> Optional[str]:
    try:
        sm.delete_secret(SecretId=arn, RecoveryWindowInDays=recovery_days, ForceDeleteWithoutRecovery=False)
        return None
    except Exception as e:
        return str(e)


def main():
    args = parse_args()
    sess = session(args.profile)
    regions = discover_regions(sess, args.regions)
    needed_tags = parse_tag_filters(args.required_tag)

    now = dt.datetime.utcnow()

    results = []
    applied = 0

    for region in regions:
        sm = sess.client("secretsmanager", region_name=region)
        try:
            secrets = list_secrets(sm)
        except Exception as e:
            print(f"WARN region {region} list secrets failed: {e}", file=sys.stderr)
            continue

        for s in secrets:
            name = s.get("Name") or ""
            arn = s.get("ARN")
            if args.name_filter and args.name_filter not in name:
                continue

            # Tag filter
            tags = {t.get("Key"): t.get("Value") for t in (s.get("Tags") or [])}
            if needed_tags:
                ok = True
                for k, v in needed_tags.items():
                    if tags.get(k) != v:
                        ok = False
                        break
                if not ok:
                    continue

            # Describe for dates and rotation
            try:
                desc = sm.describe_secret(SecretId=arn)
            except Exception:
                continue

            last_accessed = desc.get("LastAccessedDate")
            last_rotated = desc.get("LastRotatedDate")
            rotation_enabled = bool(desc.get("RotationEnabled"))

            access_age_days = None
            rotate_age_days = None
            if isinstance(last_accessed, dt.datetime):
                if last_accessed.tzinfo:
                    last_accessed = last_accessed.astimezone(dt.timezone.utc).replace(tzinfo=None)
                access_age_days = (now - last_accessed).days
            if isinstance(last_rotated, dt.datetime):
                if last_rotated.tzinfo:
                    last_rotated = last_rotated.astimezone(dt.timezone.utc).replace(tzinfo=None)
                rotate_age_days = (now - last_rotated).days

            stale_flag = False
            rotation_flag = False
            if args.stale_days is not None:
                # Consider missing LastAccessedDate as stale
                if access_age_days is None or access_age_days >= args.stale_days:
                    stale_flag = True
            if args.rotation_max_days is not None:
                # If rotation disabled or rotation older than threshold
                if (not rotation_enabled) or (rotate_age_days is not None and rotate_age_days >= args.rotation_max_days):
                    rotation_flag = True

            flagged = stale_flag or rotation_flag
            if not flagged:
                continue

            rec = {
                "region": region,
                "name": name,
                "arn": arn,
                "tags": tags,
                "rotation_enabled": rotation_enabled,
                "access_age_days": access_age_days,
                "rotate_age_days": rotate_age_days,
                "stale": stale_flag,
                "rotation_old": rotation_flag,
                "tag_attempted": False,
                "tag_error": None,
                "delete_attempted": False,
                "delete_error": None,
            }

            if args.apply_tag and applied < args.max_apply and arn:
                err = tag_secret(sm, arn, args.tag_key, args.tag_value)
                rec["tag_attempted"] = True
                rec["tag_error"] = err
                if err is None:
                    applied += 1

            if args.schedule_delete and applied < args.max_apply and arn:
                err = schedule_delete(sm, arn, args.recovery_days)
                rec["delete_attempted"] = True
                rec["delete_error"] = err
                if err is None:
                    applied += 1

            results.append(rec)

    payload = {
        "regions": regions,
        "stale_days": args.stale_days,
        "rotation_max_days": args.rotation_max_days,
        "apply_tag": args.apply_tag,
        "schedule_delete": args.schedule_delete,
        "recovery_days": args.recovery_days,
        "applied": applied,
        "results": results,
    }

    if args.json:
        print(json.dumps(payload, indent=2))
        return 0

    if not results:
        print("No stale or unrotated secrets found under current criteria.")
        return 0

    header = ["Region", "Name", "AccessAge(d)", "RotateAge(d)", "RotEnabled", "Tagged", "Scheduled"]
    rows = [header]
    for r in results:
        rows.append([
            r["region"], r["name"], ("-" if r.get("access_age_days") is None else r.get("access_age_days")),
            ("-" if r.get("rotate_age_days") is None else r.get("rotate_age_days")),
            ("Y" if r.get("rotation_enabled") else "N"),
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

    if not args.apply_tag and not args.schedule_delete:
        print("\nDry-run. Use --apply-tag to mark, or --schedule-delete to schedule deletion with recovery window.")
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
