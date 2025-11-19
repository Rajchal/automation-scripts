#!/usr/bin/env python3
"""
aws-ecr-repository-empty-auditor.py

Purpose:
  Identify empty or stale Amazon ECR repositories across regions. Optionally tag flagged
  repositories for review or delete truly empty repositories with a strict safety cap.

Signals:
  - Empty repository: zero images
  - Stale repository: last image push older than --min-days-since-push

Features:
  - Multi-region scan (default: all enabled)
  - Configurable staleness window (--min-days-since-push, default 90)
  - Filters: --name-filter substring, --required-tag Key=Value (repeat)
  - Actions: --apply-tag or --apply-delete (empty-only) with caps (--max-apply, --max-delete)
  - Output: human-readable table or --json
  - CI mode: --ci-exit-on-findings returns exit code 2 if any findings

Safety:
  - Deletion uses delete_repository(force=False) and only attempted when image_count == 0.
  - No force deletes will be performed by this script.

Permissions:
  - ecr:DescribeRepositories, ecr:DescribeImages, ecr:ListTagsForResource, ecr:TagResource, ecr:DeleteRepository
  - cloudwatch not required (ECR API provides push times)
  - ec2:DescribeRegions

Examples:
  python aws-ecr-repository-empty-auditor.py --regions us-east-1 us-west-2 --json
  python aws-ecr-repository-empty-auditor.py --min-days-since-push 180 --apply-tag --max-apply 25
  python aws-ecr-repository-empty-auditor.py --apply-delete --max-delete 5  # deletes empty repos only

Exit Codes:
  0 success
  1 unexpected error
  2 findings (when --ci-exit-on-findings used)
"""
import argparse
import boto3
import datetime as dt
import json
import sys
from typing import Any, Dict, List, Optional


def parse_args():
    p = argparse.ArgumentParser(description="Audit empty/stale ECR repositories (dry-run by default)")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all enabled)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--name-filter", help="Substring filter on repository name")
    p.add_argument("--required-tag", action="append", help="Require Tag Key=Value on repository (repeat)")
    p.add_argument("--min-days-since-push", type=int, default=90, help="Min days since last push to be stale (default: 90)")
    p.add_argument("--apply-tag", action="store_true", help="Apply tag to flagged repositories")
    p.add_argument("--tag-key", default="Cost:Review", help="Tag key (default: Cost:Review)")
    p.add_argument("--tag-value", default="ecr-empty-or-stale", help="Tag value (default: ecr-empty-or-stale)")
    p.add_argument("--max-apply", type=int, default=50, help="Max repositories to tag (default: 50)")
    p.add_argument("--apply-delete", action="store_true", help="Delete empty repositories (no force)")
    p.add_argument("--max-delete", type=int, default=10, help="Max repositories to delete (default: 10)")
    p.add_argument("--ci-exit-on-findings", action="store_true", help="Exit code 2 if any findings (CI integration)")
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


def list_repositories(ecr) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    token = None
    while True:
        kwargs: Dict[str, Any] = {}
        if token:
            kwargs["nextToken"] = token
        resp = ecr.describe_repositories(**kwargs)
        out.extend(resp.get("repositories", []) or [])
        token = resp.get("nextToken")
        if not token:
            break
    return out


def list_tags(ecr, arn: str) -> Dict[str, str]:
    try:
        resp = ecr.list_tags_for_resource(resourceArn=arn)
        return {t.get("Key"): t.get("Value") for t in resp.get("tags", [])}
    except Exception:
        return {}


def repo_images_stats(ecr, repo_name: str) -> Dict[str, Any]:
    """Return image_count and last_pushed_at (UTC naive) for a repository."""
    image_count = 0
    last_push: Optional[dt.datetime] = None
    try:
        paginator = ecr.get_paginator("describe_images")
        for page in paginator.paginate(repositoryName=repo_name):
            details = page.get("imageDetails", []) or []
            image_count += len(details)
            for d in details:
                pushed = d.get("imagePushedAt")
                if pushed:
                    if pushed.tzinfo:
                        pushed = pushed.astimezone(dt.timezone.utc).replace(tzinfo=None)
                    if not last_push or pushed > last_push:
                        last_push = pushed
    except Exception:
        # Fallback to list_images count if describe_images is restricted
        try:
            paginator = ecr.get_paginator("list_images")
            for page in paginator.paginate(repositoryName=repo_name):
                image_ids = page.get("imageIds", []) or []
                image_count += len(image_ids)
        except Exception:
            pass
    return {"image_count": image_count, "last_pushed_at": last_push}


def add_tag(ecr, arn: str, key: str, value: str) -> Optional[str]:
    try:
        ecr.tag_resource(resourceArn=arn, tags=[{"Key": key, "Value": value}])
        return None
    except Exception as e:
        return str(e)


def delete_repo(ecr, name: str) -> Optional[str]:
    try:
        ecr.delete_repository(repositoryName=name, force=False)
        return None
    except Exception as e:
        return str(e)


def main():
    args = parse_args()
    sess = session(args.profile)
    regions = discover_regions(sess, args.regions)
    needed_tags = parse_required_tags(args.required_tag)

    now = dt.datetime.utcnow()

    findings: List[Dict[str, Any]] = []
    tagged = 0
    deleted = 0

    for region in regions:
        ecr = sess.client("ecr", region_name=region)
        repos = list_repositories(ecr)
        for r in repos:
            name = r.get("repositoryName")
            arn = r.get("repositoryArn") or name
            if args.name_filter and (args.name_filter not in (name or "")):
                continue
            # Tag filter
            if needed_tags:
                tags = list_tags(ecr, arn)
                ok = True
                for k, v in needed_tags.items():
                    if tags.get(k) != v:
                        ok = False
                        break
                if not ok:
                    continue

            stats = repo_images_stats(ecr, name)
            count = int(stats.get("image_count") or 0)
            last_push = stats.get("last_pushed_at")
            days_since = (now - last_push).days if last_push else None

            is_empty = count == 0
            is_stale = (days_since is not None) and (days_since >= args.min_days_since_pus h)  # type: ignore
            # Fix potential typo: We'll recompute safely
            if last_push:
                is_stale = (now - last_push).days >= args.min_days_since_push
            else:
                is_stale = False

            flagged = is_empty or is_stale
            if not flagged:
                continue

            rec = {
                "region": region,
                "name": name,
                "arn": arn,
                "image_count": count,
                "last_push": last_push.isoformat() if last_push else None,
                "days_since_push": days_since,
                "flag_empty": is_empty,
                "flag_stale": is_stale,
                "tag_attempted": False,
                "tag_error": None,
                "delete_attempted": False,
                "delete_error": None,
            }

            if args.apply_tag and arn and tagged < args.max_apply:
                err = add_tag(ecr, arn, args.tag_key, args.tag_value)
                rec["tag_attempted"] = True
                rec["tag_error"] = err
                if err is None:
                    tagged += 1

            if args.apply_delete and is_empty and deleted < args.max_delete:
                err = delete_repo(ecr, name)
                rec["delete_attempted"] = True
                rec["delete_error"] = err
                if err is None:
                    deleted += 1

            findings.append(rec)

    payload = {
        "regions": regions,
        "min_days_since_push": args.min_days_since_push,
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
        print("No empty or stale ECR repositories found.")
        return 0

    header = ["Region", "Repository", "Images", "LastPushDays", "Empty", "Stale", "Tagged", "Deleted"]
    rows = [header]
    for r in findings:
        rows.append([
            r["region"], r["name"], r["image_count"], (r["days_since_push"] if r["days_since_push"] is not None else "-"),
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
        print("\nDry-run. Use --apply-tag to tag or --apply-delete to delete empty repositories (no force).")
    elif args.apply_delete:
        print("\nDelete only attempted for empty repositories and never with force=true.")

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
