#!/usr/bin/env python3
"""
aws-ecr-untagged-image-pruner.py

Purpose:
  Enumerate untagged (dangling) ECR images older than a retention window and
  optionally delete them to reclaim storage. Default is dry‑run (no deletions).

Features:
  - Multi-region scanning
  - Filters repositories by name substring (--repo-filter)
  - Age threshold (--days) for untagged images based on imagePushedAt
  - Batch deletion with --apply flag
  - JSON output for integration

Safety:
  - Dry-run unless --apply is specified
  - Skips images that still have tags (defensive; API should not list them when filtering untagged anyway)

Requires:
  - boto3
  - Permissions: ecr:DescribeRepositories, ecr:ListImages, ecr:BatchGetImage, ecr:BatchDeleteImage

Examples:
  python aws-ecr-untagged-image-pruner.py --regions us-east-1 us-west-2 --days 14
  python aws-ecr-untagged-image-pruner.py --profile prod --repo-filter backend --days 30 --apply
  python aws-ecr-untagged-image-pruner.py --json --days 60

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
    p = argparse.ArgumentParser(description="Prune (delete) old untagged ECR images (dry-run by default)")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all available)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--days", type=int, default=30, help="Minimum age in days for untagged images to be considered")
    p.add_argument("--repo-filter", help="Substring filter for repository name")
    p.add_argument("--max-delete", type=int, default=200, help="Max images to delete per repository per run")
    p.add_argument("--apply", action="store_true", help="Actually delete instead of dry-run")
    p.add_argument("--json", action="store_true", help="Output JSON")
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


def list_repositories(ecr):
    repos = []
    token = None
    while True:
        kwargs = {"maxResults": 1000}
        if token:
            kwargs["nextToken"] = token
        resp = ecr.describe_repositories(**kwargs)
        repos.extend(resp.get("repositories", []))
        token = resp.get("nextToken")
        if not token:
            break
    return repos


def list_untagged_image_digests(ecr, repo_name: str):
    digests = []
    token = None
    while True:
        kwargs = {"repositoryName": repo_name, "filter": {"tagStatus": "UNTAGGED"}, "maxResults": 1000}
        if token:
            kwargs["nextToken"] = token
        resp = ecr.list_images(**kwargs)
        for img in resp.get("imageIds", []):
            if img.get("imageTag"):
                continue
            if img.get("imageDigest"):
                digests.append({"imageDigest": img["imageDigest"]})
        token = resp.get("nextToken")
        if not token:
            break
    return digests


def batch_get_images(ecr, repo_name: str, digests: List[Dict[str, str]]):
    out = []
    for i in range(0, len(digests), 100):
        chunk = digests[i:i+100]
        try:
            resp = ecr.batch_get_image(repositoryName=repo_name, imageIds=chunk, acceptedMediaTypes=["application/vnd.docker.distribution.manifest.v2+json"])  # noqa
        except Exception:
            continue
        # Provided metadata does not include pushedAt; need describe_images instead
    return out


def describe_images(ecr, repo_name: str, digests: List[Dict[str, str]]):
    images = []
    for i in range(0, len(digests), 100):
        chunk = digests[i:i+100]
        try:
            resp = ecr.describe_images(repositoryName=repo_name, imageIds=chunk)
        except Exception:
            continue
        images.extend(resp.get("imageDetails", []))
    return images


def batch_delete(ecr, repo_name: str, digests: List[Dict[str, str]]):
    deleted = []
    failures = []
    for i in range(0, len(digests), 100):
        chunk = digests[i:i+100]
        try:
            resp = ecr.batch_delete_image(repositoryName=repo_name, imageIds=chunk)
            deleted.extend(resp.get("imageIds", []))
            failures.extend(resp.get("failures", []))
        except Exception as e:
            failures.append({"reason": str(e), "imageIds": chunk})
    return deleted, failures


def human_size(num: float) -> str:
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if num < 1024:
            return f"{num:.1f}{unit}"
        num /= 1024
    return f"{num:.1f}PB"


def main():
    args = parse_args()
    sess = session(args.profile)
    regs = regions(sess, args.regions)
    cutoff = dt.datetime.utcnow() - dt.timedelta(days=args.days)
    all_results = []

    for region in regs:
        ecr = sess.client("ecr", region_name=region)
        try:
            repos = list_repositories(ecr)
        except Exception as e:
            print(f"WARN region {region} describe_repositories failed: {e}", file=sys.stderr)
            continue
        for repo in repos:
            name = repo.get("repositoryName")
            if args.repo_filter and args.repo_filter not in name:
                continue
            digests = list_untagged_image_digests(ecr, name)
            if not digests:
                continue
            details = describe_images(ecr, name, digests)
            old_images = []
            for d in details:
                pushed = d.get("imagePushedAt")
                if not pushed:
                    continue
                if pushed.tzinfo:
                    pushed = pushed.astimezone(dt.timezone.utc).replace(tzinfo=None)
                if pushed > cutoff:
                    continue
                if d.get("imageTags"):
                    continue  # safety
                old_images.append(d)
            if not old_images:
                continue
            # Sort by age ascending so we prune oldest first (arbitrary)
            old_images.sort(key=lambda x: x.get("imagePushedAt"))
            to_delete = [{"imageDigest": im.get("imageDigest") or ""} for im in old_images][:args.max_delete]
            deleted = []
            failures = []
            if args.apply:
                deleted, failures = batch_delete(ecr, name, to_delete)
            size_sum = 0
            for img in old_images:
                # size may be missing; accumulate if present
                size_sum += img.get("imageSizeInBytes", 0)
            rec = {
                "region": region,
                "repository": name,
                "total_old_untagged": len(old_images),
                "deleted_attempted": len(to_delete) if args.apply else 0,
                "deleted": len(deleted),
                "failures": failures,
                "size_reclaimable_bytes": size_sum,
                "size_reclaimable_human": human_size(size_sum),
                "apply": args.apply,
                "sample_digests": [i.get("imageDigest") for i in old_images[:5]],
            }
            all_results.append(rec)

    if args.json:
        print(json.dumps({
            "regions": regs,
            "cutoff_days": args.days,
            "apply": args.apply,
            "results": all_results,
        }, indent=2, default=str))
        return 0

    # Human output
    header = ["Region", "Repository", "OldUntagged", "Reclaimable", "WillDelete", "Apply"]
    rows = [header]
    for r in all_results:
        rows.append([
            r["region"], r["repository"], r["total_old_untagged"], r["size_reclaimable_human"], r["deleted_attempted"], str(r["apply"])
        ])
    if len(rows) == 1:
        print("No old untagged images found over threshold.")
        return 0
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = "  ".join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print("  ".join("-" * w for w in widths))
        else:
            print(line)
    if not args.apply:
        print("\nDry-run only. Use --apply to perform deletions.")
    print("Suggestions: Consider ECR lifecycle policies for automatic cleanup.")
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
