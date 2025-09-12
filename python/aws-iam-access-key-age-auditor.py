#!/usr/bin/env python3
"""
aws-iam-access-key-age-auditor.py

Purpose:
  Audit IAM user access keys for excessive age and inactivity to enforce key
  rotation and hygiene policies. Optionally deactivate (set to Inactive) keys
  that exceed thresholds when --deactivate is provided.

Checks:
  - Key age > --max-age-days (default 90)
  - Days since last use > --unused-days (default 45) (uses IAM GetAccessKeyLastUsed)

Features:
  - Filter users by prefix (--user-prefix) or regex (--user-regex)
  - Exclude users (--exclude-user) can repeat
  - JSON output option
  - Dry-run by default (no changes) unless --deactivate passed
  - Optional --profile (single account; assume-role external script can wrap)

Permissions Required:
  - iam:ListUsers, iam:ListAccessKeys, iam:GetAccessKeyLastUsed, iam:UpdateAccessKey

Examples:
  python aws-iam-access-key-age-auditor.py --profile prod --max-age-days 120 --unused-days 60
  python aws-iam-access-key-age-auditor.py --user-prefix svc- --deactivate --json

Exit Codes:
  0 success (no findings OR deactivation succeeded)
  1 unexpected error
  2 findings (when not deactivating) OR flagged keys existed
"""
import argparse
import boto3
import datetime as dt
import json
import re
import sys
from typing import List, Dict, Any, Optional


def parse_args():
    p = argparse.ArgumentParser(description="Audit IAM access key age and usage")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--max-age-days", type=int, default=90, help="Max allowed key age before flagging")
    p.add_argument("--unused-days", type=int, default=45, help="Max allowed days since last use before flagging")
    p.add_argument("--user-prefix", help="Only include users whose name starts with this prefix")
    p.add_argument("--user-regex", help="Only include users matching this regex")
    p.add_argument("--exclude-user", action="append", help="Usernames to exclude (can repeat)")
    p.add_argument("--deactivate", action="store_true", help="Set flagged keys to Inactive")
    p.add_argument("--json", action="store_true", help="JSON output")
    return p.parse_args()


def session(profile: Optional[str]):
    if profile:
        return boto3.Session(profile_name=profile)
    return boto3.Session()


def list_users(iam):
    users = []
    marker = None
    while True:
        kwargs = {}
        if marker:
            kwargs["Marker"] = marker
        resp = iam.list_users(**kwargs)
        users.extend(resp.get("Users", []))
        if not resp.get("IsTruncated"):
            break
        marker = resp.get("Marker")
    return users


def list_access_keys(iam, user_name: str):
    keys = []
    marker = None
    while True:
        kwargs = {"UserName": user_name}
        if marker:
            kwargs["Marker"] = marker
        resp = iam.list_access_keys(**kwargs)
        keys.extend(resp.get("AccessKeyMetadata", []))
        if not resp.get("IsTruncated"):
            break
        marker = resp.get("Marker")
    return keys


def last_used(iam, access_key_id: str):
    try:
        resp = iam.get_access_key_last_used(AccessKeyId=access_key_id)
        info = resp.get("AccessKeyLastUsed", {})
        return info.get("LastUsedDate")
    except Exception:
        return None


def deactivate_key(iam, user: str, key_id: str) -> Optional[str]:
    try:
        iam.update_access_key(UserName=user, AccessKeyId=key_id, Status="Inactive")
        return None
    except Exception as e:
        return str(e)


def user_included(user: str, args) -> bool:
    if args.exclude_user and user in args.exclude_user:
        return False
    if args.user_prefix and not user.startswith(args.user_prefix):
        return False
    if args.user_regex and not re.search(args.user_regex, user):
        return False
    return True


def classify_key(key_meta: Dict[str, Any], last_used_dt, args, now: dt.datetime):
    created = key_meta.get("CreateDate")
    if created and created.tzinfo:
        created = created.astimezone(dt.timezone.utc).replace(tzinfo=None)
    age_days = (now - created).days if created else None
    unused_days = None
    if last_used_dt:
        if last_used_dt.tzinfo:
            last_used_dt = last_used_dt.astimezone(dt.timezone.utc).replace(tzinfo=None)
        unused_days = (now - last_used_dt).days
    else:
        # Never used -> consider as age since creation
        if created:
            unused_days = age_days
    reasons = []
    status = "OK"
    if age_days is not None and age_days > args.max_age_days:
        status = "FLAGGED"
        reasons.append(f"age {age_days}d > {args.max_age_days}")
    if unused_days is not None and unused_days > args.unused_days:
        if status == "OK":
            status = "FLAGGED"
        reasons.append(f"unused {unused_days}d > {args.unused_days}")
    return status, reasons, age_days, unused_days


def main():
    args = parse_args()
    sess = session(args.profile)
    iam = sess.client("iam")
    now = dt.datetime.utcnow()

    users = list_users(iam)
    findings = []

    for u in users:
        user_name = u.get("UserName")
        if not user_included(user_name, args):
            continue
        keys = list_access_keys(iam, user_name)
        for km in keys:
            key_id = km.get("AccessKeyId")
            status = km.get("Status")
            lu = last_used(iam, key_id)
            key_status, reasons, age_days, unused_days = classify_key(km, lu, args, now)
            entry = {
                "user": user_name,
                "key_id": key_id,
                "orig_status": status,
                "classification": key_status,
                "reasons": reasons,
                "age_days": age_days,
                "unused_days": unused_days,
                "last_used": str(lu) if lu else None,
                "deactivate_attempted": False,
                "deactivate_error": None,
            }
            if key_status == "FLAGGED" and args.deactivate and status != "Inactive":
                err = deactivate_key(iam, user_name, key_id)
                entry["deactivate_attempted"] = True
                entry["deactivate_error"] = err
            findings.append(entry)

    flagged = [f for f in findings if f['classification'] == 'FLAGGED']

    if args.json:
        print(json.dumps({
            "max_age_days": args.max_age_days,
            "unused_days": args.unused_days,
            "users_scanned": len({f['user'] for f in findings}),
            "flagged_count": len(flagged),
            "deactivate": args.deactivate,
            "findings": findings,
        }, indent=2))
        return 2 if flagged and not args.deactivate else 0

    if not flagged:
        print("No access keys exceeded thresholds.")
        return 0

    header = ["User", "KeyId", "Age(d)", "Unused(d)", "OrigStatus", "Deact"]
    rows = [header]
    for f in flagged:
        rows.append([
            f['user'], f['key_id'], f.get('age_days'), f.get('unused_days'), f.get('orig_status'),
            'Y' if f['deactivate_attempted'] and not f['deactivate_error'] else ('ERR' if f['deactivate_error'] else 'N')
        ])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = "  ".join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print("  ".join("-" * w for w in widths))
        else:
            print(line)
    if args.deactivate:
        print("\nDeactivation attempted for flagged active keys.")
    else:
        print("\nFlagged keys found; consider rotating or use --deactivate to set Inactive.")
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("Interrupted", file=sys.stderr)
        sys.exit(130)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)