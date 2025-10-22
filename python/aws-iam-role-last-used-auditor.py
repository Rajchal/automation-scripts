#!/usr/bin/env python3
"""
aws-iam-role-last-used-auditor.py

Purpose:
  Audit IAM roles for inactivity by inspecting RoleLastUsed.LastUsedDate. Useful to identify
  roles that can be reviewed, minimized, or removed. Supports filters and safe tagging for review.

Features:
  - Global scan (IAM is global)
  - Filters:
      * --stale-days N: flag roles not used in the last N days (or never used)
      * --name-filter substring match on role name
      * --path-prefix filter by role path prefix (e.g., /service-role/)
      * --required-tag Key=Value (repeatable)
      * --exclude-service-linked: skip AWS Service-Linked Roles
  - Actions (dry-run by default):
      * --apply-tag with --tag-key/--tag-value and --max-apply
  - Output: human-readable table or --json
  - CI-friendly: --fail-on-findings exit 2 when flagged roles exist

Safety:
  - Read-only unless tag application is requested. No role deletions are performed.

Permissions:
  - iam:ListRoles, iam:ListRoleTags, iam:TagRole

Examples:
  python aws-iam-role-last-used-auditor.py --stale-days 90 --json
  python aws-iam-role-last-used-auditor.py --exclude-service-linked --apply-tag --max-apply 20

Exit Codes:
  0 success
  1 unexpected error
  2 findings detected with --fail-on-findings
"""
import argparse
import boto3
import datetime as dt
import json
import sys
from typing import Any, Dict, List, Optional


def parse_args():
    p = argparse.ArgumentParser(description="Audit IAM roles for inactivity (dry-run by default)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--stale-days", type=int, default=90, help="Flag roles not used in last N days (default: 90)")
    p.add_argument("--name-filter", help="Substring filter on role name")
    p.add_argument("--path-prefix", default="/", help="Filter by IAM role path prefix (default: /)")
    p.add_argument("--required-tag", action="append", help="Require Tag Key=Value to include (repeat)")
    p.add_argument("--exclude-service-linked", action="store_true", help="Skip AWS Service-Linked Roles")
    p.add_argument("--apply-tag", action="store_true", help="Tag flagged roles for review")
    p.add_argument("--tag-key", default="Cost:Review", help="Tag key (default: Cost:Review)")
    p.add_argument("--tag-value", default="role-stale", help="Tag value (default: role-stale)")
    p.add_argument("--max-apply", type=int, default=100, help="Max roles to tag (default: 100)")
    p.add_argument("--fail-on-findings", action="store_true", help="Exit code 2 if findings exist")
    p.add_argument("--json", action="store_true", help="JSON output")
    return p.parse_args()


def session(profile: Optional[str]):
    if profile:
        return boto3.Session(profile_name=profile)
    return boto3.Session()


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


def list_roles(iam, path_prefix: str) -> List[Dict[str, Any]]:
    roles: List[Dict[str, Any]] = []
    marker = None
    while True:
        kwargs = {"PathPrefix": path_prefix}
        if marker:
            kwargs["Marker"] = marker
        resp = iam.list_roles(**kwargs)
        roles.extend(resp.get("Roles", []) or [])
        if resp.get("IsTruncated"):
            marker = resp.get("Marker")
        else:
            break
    return roles


def list_role_tags(iam, role_name: str) -> Dict[str, str]:
    try:
        resp = iam.list_role_tags(RoleName=role_name)
        return {t.get("Key"): t.get("Value") for t in resp.get("Tags", [])}
    except Exception:
        return {}


def tag_role(iam, role_name: str, key: str, value: str) -> Optional[str]:
    try:
        iam.tag_role(RoleName=role_name, Tags=[{"Key": key, "Value": value}])
        return None
    except Exception as e:
        return str(e)


def is_service_linked(role: Dict[str, Any]) -> bool:
    # Heuristic: AWS Service-Linked Roles often have a path of "/aws-service-role/" and a description mentioning service-linked role
    path = role.get("Path") or ""
    desc = role.get("Description") or ""
    arn = role.get("Arn") or ""
    return "/aws-service-role/" in path or "service-linked role" in desc.lower() or ":role/aws-service-role/" in arn


def main():
    args = parse_args()
    sess = session(args.profile)
    iam = sess.client("iam")

    needed_tags = parse_tag_filters(args.required_tag)

    now = dt.datetime.utcnow()

    try:
        roles = list_roles(iam, args.path_prefix)
    except Exception as e:
        print(f"ERROR listing roles: {e}", file=sys.stderr)
        return 1

    results = []
    applied = 0

    for r in roles:
        name = r.get("RoleName")
        if args.name_filter and args.name_filter not in name:
            continue
        if args.exclude_service_linked and is_service_linked(r):
            continue

        tags = list_role_tags(iam, name)
        if needed_tags:
            ok = True
            for k, v in needed_tags.items():
                if tags.get(k) != v:
                    ok = False
                    break
            if not ok:
                continue

        last_used = (r.get("RoleLastUsed") or {}).get("LastUsedDate")
        age_days = None
        if isinstance(last_used, dt.datetime):
            if last_used.tzinfo:
                last_used = last_used.astimezone(dt.timezone.utc).replace(tzinfo=None)
            age_days = (now - last_used).days

        # Never used: treat as stale for any positive threshold
        stale = False
        if args.stale_days is not None:
            if age_days is None or age_days >= args.stale_days:
                stale = True

        if not stale:
            continue

        rec = {
            "role_name": name,
            "path": r.get("Path"),
            "arn": r.get("Arn"),
            "create_date": r.get("CreateDate").isoformat() if isinstance(r.get("CreateDate"), dt.datetime) else None,
            "last_used_age_days": age_days,
            "last_used_region": (r.get("RoleLastUsed") or {}).get("Region"),
            "service_linked": is_service_linked(r),
            "tag_attempted": False,
            "tag_error": None,
        }

        if args.apply_tag and applied < args.max_apply:
            err = tag_role(iam, name, args.tag_key, args.tag_value)
            rec["tag_attempted"] = True
            rec["tag_error"] = err
            if err is None:
                applied += 1

        results.append(rec)

    payload = {
        "stale_days": args.stale_days,
        "exclude_service_linked": args.exclude_service_linked,
        "apply_tag": args.apply_tag,
        "applied": applied,
        "results": results,
    }

    if args.json:
        print(json.dumps(payload, indent=2))
        return 0 if (results or not args.fail_on_findings) else 2

    if not results:
        print("No stale IAM roles found under current criteria.")
        return 0

    header = ["Role", "Path", "LastUsedAge(d)", "Region", "SvcLinked", "Tagged"]
    rows = [header]
    for r in results:
        rows.append([
            r["role_name"], r.get("path") or "-",
            ("-" if r.get("last_used_age_days") is None else r.get("last_used_age_days")),
            r.get("last_used_region") or "-",
            "Y" if r.get("service_linked") else "N",
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

    if args.fail_on_findings and results:
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
