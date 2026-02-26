#!/usr/bin/env python3
"""artifactory_cleanup.py

Find and optionally delete artifacts in an Artifactory repo older than N days.

This script uses the Artifactory AQL API and works with either an API key
(`X-JFrog-Art-Api` environment variable) or basic auth via `ART_USER` and
`ART_PASSWORD` environment variables.

Dry-run is the default; pass `--apply` to perform deletions.

Usage:
  python artifactory_cleanup.py --url https://artifactory.example.com --repo my-repo --days 90
  python artifactory_cleanup.py --repo my-repo --days 30 --apply
"""
from __future__ import annotations
import argparse
import datetime
import json
import os
import sys
import urllib.request
import urllib.error


def build_aql(repo: str, iso_before: str, path_prefix: str | None) -> str:
    # AQL: find files in repo modified before iso_before
    criteria = {"repo": repo, "type": "file", "modified": {"$before": iso_before}}
    if path_prefix:
        # match path starting with prefix (AQL doesn't support startsWith directly, use path property)
        criteria["path"] = {"$match": f"{path_prefix}*"}
    # include necessary fields
    aql = f'items.find({json.dumps(criteria)}).include("repo","path","name","modified")'
    return aql


def post_aql(base_url: str, aql: str, headers: dict) -> dict:
    url = base_url.rstrip("/") + "/api/search/aql"
    data = aql.encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers or {}, method="POST")
    with urllib.request.urlopen(req) as resp:
        body = resp.read()
        return json.loads(body)


def delete_item(base_url: str, repo: str, path: str, name: str, headers: dict) -> None:
    # DELETE https://.../{repo}/{path}/{name}
    # path may be empty
    full_path = "/".join([p for p in [base_url.rstrip("/"), repo, path, name] if p != ""])
    req = urllib.request.Request(full_path, headers=headers or {}, method="DELETE")
    with urllib.request.urlopen(req) as resp:
        resp.read()


def main() -> int:
    parser = argparse.ArgumentParser(description="Cleanup old artifacts in Artifactory")
    parser.add_argument("--url", default=os.environ.get("ARTIFACTORY_URL", ""), help="Artifactory base URL")
    parser.add_argument("--repo", required=True, help="Repository name")
    parser.add_argument("--days", type=int, required=True, help="Delete artifacts older than this many days")
    parser.add_argument("--path-prefix", help="Limit to artifacts under this path prefix")
    parser.add_argument("--apply", action="store_true", help="Perform deletions (default is dry-run)")
    args = parser.parse_args()

    base_url = args.url or os.environ.get("ARTIFACTORY_URL")
    if not base_url:
        print("Artifactory URL must be provided via --url or ARTIFACTORY_URL env var", file=sys.stderr)
        return 2

    # Auth headers
    headers: dict = {"Content-Type": "text/plain"}
    api_key = os.environ.get("X_JFROG_ART_API") or os.environ.get("ARTIFACTORY_API_KEY") or os.environ.get("X-JFrog-Art-Api")
    if api_key:
        headers["X-JFrog-Art-Api"] = api_key
    else:
        # try basic auth
        user = os.environ.get("ART_USER")
        pwd = os.environ.get("ART_PASSWORD")
        if user and pwd:
            import base64

            auth = f"{user}:{pwd}".encode("utf-8")
            headers["Authorization"] = "Basic " + base64.b64encode(auth).decode("ascii")
        else:
            print("Warning: no API key or basic auth provided; requests may be unauthenticated", file=sys.stderr)

    cutoff = datetime.datetime.utcnow() - datetime.timedelta(days=args.days)
    iso_cutoff = cutoff.replace(microsecond=0).isoformat() + "Z"

    aql = build_aql(args.repo, iso_cutoff, args.path_prefix)
    try:
        res = post_aql(base_url, aql, headers)
    except urllib.error.HTTPError as e:
        print(f"AQL query failed: {e.code} {e.reason}", file=sys.stderr)
        try:
            print(e.read().decode(), file=sys.stderr)
        except Exception:
            pass
        return 3

    results = res.get("results", [])
    if not results:
        print("No artifacts found matching criteria.")
        return 0

    print(f"Found {len(results)} artifacts older than {args.days} days in repo {args.repo}.")
    for item in results:
        repo = item.get("repo")
        path = item.get("path", "")
        name = item.get("name")
        modified = item.get("modified")
        display = f"{repo}/{path}/{name}" if path else f"{repo}/{name}"
        print(display + f"  (modified: {modified})")

    if not args.apply:
        print("Dry-run; no deletions performed. Re-run with --apply to delete.")
        return 0

    # perform deletions
    errors = 0
    for item in results:
        repo = item.get("repo")
        path = item.get("path", "")
        name = item.get("name")
        try:
            delete_item(base_url, repo, path, name, headers)
            print(f"Deleted: {repo}/{path}/{name}" if path else f"Deleted: {repo}/{name}")
        except urllib.error.HTTPError as e:
            print(f"Failed to delete {repo}/{path}/{name}: {e.code} {e.reason}", file=sys.stderr)
            errors += 1
        except Exception as e:
            print(f"Failed to delete {repo}/{path}/{name}: {e}", file=sys.stderr)
            errors += 1

    if errors:
        print(f"Completed with {errors} errors", file=sys.stderr)
        return 4

    print("Deletion completed successfully.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
