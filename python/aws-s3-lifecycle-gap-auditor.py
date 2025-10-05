#!/usr/bin/env python3
"""
aws-s3-lifecycle-gap-auditor.py

Purpose:
  Detect S3 buckets that are missing lifecycle configurations (cost hygiene) or missing
  transition/expiration actions, and optionally apply a simple lifecycle template.

Features:
  - Global bucket scan with per-bucket region resolution
  - Filters:
      * --name-filter substring to include buckets
      * --required-tag Key=Value (repeatable) to include only tagged buckets
      * --exclude-bucket NAME (repeatable)
  - Checks:
      * Missing lifecycle configuration entirely
      * Optionally, missing transition actions (--require-transition)
      * Optionally, missing expiration for noncurrent versions (--require-expiration)
  - Remediation (safe, opt-in):
      * --apply-template to install a minimal lifecycle config with transitions/expiration
      * --days-to-ia (default 30), --days-to-glacier (default 90),
        --noncurrent-days-to-expire (default 365)
      * --rule-id and --prefix for the created rule (defaults provided)
      * --max-apply cap
  - JSON or human-readable output

Safety:
  - Read-only by default; applying lifecycle rules is idempotent (will overwrite same RuleId if present).

Permissions:
  - s3:ListAllMyBuckets, s3:GetBucketLocation, s3:GetLifecycleConfiguration, s3:PutLifecycleConfiguration, s3:GetBucketTagging

Examples:
  python aws-s3-lifecycle-gap-auditor.py --json
  python aws-s3-lifecycle-gap-auditor.py --require-transition --apply-template --max-apply 10
  python aws-s3-lifecycle-gap-auditor.py --name-filter logs --days-to-ia 30 --days-to-glacier 180

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
    p = argparse.ArgumentParser(description="Audit S3 lifecycle gaps and optionally apply a template")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--name-filter", help="Substring filter for bucket name")
    p.add_argument("--required-tag", action="append", help="Require Tag Key=Value to include (repeat)")
    p.add_argument("--exclude-bucket", action="append", help="Bucket names to exclude (repeat)")
    p.add_argument("--require-transition", action="store_true", help="Flag buckets whose lifecycle lacks any transition actions")
    p.add_argument("--require-expiration", action="store_true", help="Flag buckets whose lifecycle lacks noncurrent version expiration")
    p.add_argument("--apply-template", action="store_true", help="Apply a simple lifecycle template where flagged")
    p.add_argument("--days-to-ia", type=int, default=30, help="Days to transition to STANDARD_IA/INTELLIGENT_TIERING (default: 30)")
    p.add_argument("--days-to-glacier", type=int, default=90, help="Days to transition to GLACIER (default: 90)")
    p.add_argument("--noncurrent-days-to-expire", type=int, default=365, help="Days to expire noncurrent versions (default: 365)")
    p.add_argument("--rule-id", default="cost-hygiene-default", help="Rule ID for applied template (default: cost-hygiene-default)")
    p.add_argument("--prefix", default="", help="Prefix filter for applied template (default: whole bucket)")
    p.add_argument("--max-apply", type=int, default=50, help="Max buckets to modify (default: 50)")
    p.add_argument("--use-intelligent-tiering", action="store_true", help="Use Intelligent-Tiering instead of STANDARD_IA for first transition")
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


def get_bucket_region(s3_ctrl, bucket: str) -> str:
    try:
        resp = s3_ctrl.get_bucket_location(Bucket=bucket)
        loc = resp.get("LocationConstraint")
        # us-east-1 is None per legacy behavior
        return loc or "us-east-1"
    except Exception:
        return "us-east-1"


def get_bucket_tags(s3_reg, bucket: str) -> Dict[str, str]:
    try:
        resp = s3_reg.get_bucket_tagging(Bucket=bucket)
        tags = resp.get("TagSet", [])
        return {t.get("Key"): t.get("Value") for t in tags}
    except Exception:
        return {}


def get_lifecycle(s3_reg, bucket: str) -> Optional[Dict[str, Any]]:
    try:
        return s3_reg.get_bucket_lifecycle_configuration(Bucket=bucket)
    except s3_reg.exceptions.NoSuchLifecycleConfiguration:  # type: ignore[attr-defined]
        return None
    except Exception:
        return None


def lifecycle_has_transition(cfg: Dict[str, Any]) -> bool:
    try:
        for rule in cfg.get("Rules", []):
            if any(k in rule for k in ("Transitions", "Transition")):
                trans = rule.get("Transitions") or ([] if rule.get("Transition") is None else [rule.get("Transition")])
                if trans:
                    return True
    except Exception:
        pass
    return False


def lifecycle_has_noncurrent_expiration(cfg: Dict[str, Any]) -> bool:
    try:
        for rule in cfg.get("Rules", []):
            if rule.get("NoncurrentVersionExpiration") or rule.get("NoncurrentVersionTransitions"):
                return True
    except Exception:
        pass
    return False


def build_template(rule_id: str, prefix: str, days_to_ia: int, days_to_glacier: int, noncurrent_days: int, use_intelligent: bool) -> Dict[str, Any]:
    first_storage = "INTELLIGENT_TIERING" if use_intelligent else "STANDARD_IA"
    rule = {
        "ID": rule_id,
        "Status": "Enabled",
        "Filter": {"Prefix": prefix},
        "Transitions": [
            {"Days": days_to_ia, "StorageClass": first_storage},
            {"Days": days_to_glacier, "StorageClass": "GLACIER"},
        ],
        "NoncurrentVersionExpiration": {"NoncurrentDays": noncurrent_days},
    }
    return {"Rules": [rule]}


def put_lifecycle(s3_reg, bucket: str, cfg: Dict[str, Any]) -> Optional[str]:
    try:
        s3_reg.put_bucket_lifecycle_configuration(Bucket=bucket, LifecycleConfiguration=cfg)
        return None
    except Exception as e:
        return str(e)


def main():
    args = parse_args()
    sess = session(args.profile)

    s3_ctrl = sess.client("s3")
    buckets = []
    try:
        resp = s3_ctrl.list_buckets()
        buckets = [b.get("Name") for b in resp.get("Buckets", [])]
    except Exception as e:
        print(f"ERROR listing buckets: {e}", file=sys.stderr)
        return 1

    needed_tags = parse_tag_filters(args.required_tag)

    results = []
    applied = 0

    for b in buckets:
        if args.exclude_bucket and b in args.exclude_bucket:
            continue
        if args.name_filter and args.name_filter not in b:
            continue

        region = get_bucket_region(s3_ctrl, b)
        s3_reg = sess.client("s3", region_name=region)

        tags = get_bucket_tags(s3_reg, b)
        if needed_tags:
            good = True
            for tk, tv in needed_tags.items():
                if tags.get(tk) != tv:
                    good = False
                    break
            if not good:
                continue

        cfg = get_lifecycle(s3_reg, b)
        missing_any = cfg is None
        missing_transition = False
        missing_noncurrent_exp = False
        if cfg is not None:
            if args.require_transition:
                missing_transition = not lifecycle_has_transition(cfg)
            if args.require_expiration:
                missing_noncurrent_exp = not lifecycle_has_noncurrent_expiration(cfg)

        flagged = missing_any or missing_transition or missing_noncurrent_exp
        rec = {
            "bucket": b,
            "region": region,
            "has_lifecycle": not missing_any,
            "missing_transition": missing_transition if not missing_any else True,
            "missing_noncurrent_expiration": missing_noncurrent_exp if not missing_any else True,
            "apply_attempted": False,
            "apply_error": None,
        }

        if flagged and args.apply_template and applied < args.max_apply:
            tpl = build_template(
                args.rule_id, args.prefix, args.days_to_ia, args.days_to_glacier, args.noncurrent_days_to_expire, args.use_intelligent_tiering
            )
            err = put_lifecycle(s3_reg, b, tpl)
            rec["apply_attempted"] = True
            rec["apply_error"] = err
            if err is None:
                applied += 1

        if flagged:
            results.append(rec)

    payload = {
        "buckets_scanned": len(buckets),
        "applied": applied,
        "require_transition": args.require_transition,
        "require_expiration": args.require_expiration,
        "apply_template": args.apply_template,
        "results": results,
    }

    if args.json:
        print(json.dumps(payload, indent=2))
        return 0

    if not results:
        print("No lifecycle gaps found under current criteria.")
        return 0

    header = ["Bucket", "Region", "HasLC", "MissingTransition", "MissingNoncurrentExp", "Applied"]
    rows = [header]
    for r in results:
        rows.append([
            r["bucket"], r["region"], "Y" if r["has_lifecycle"] else "N",
            "Y" if r["missing_transition"] else "N",
            "Y" if r["missing_noncurrent_expiration"] else "N",
            ("Y" if r["apply_attempted"] and not r["apply_error"] else ("ERR" if r["apply_error"] else "N")),
        ])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = '  '.join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print('  '.join('-' * w for w in widths))
        else:
            print(line)
    if not args.apply_template:
        print("\nDry-run. Use --apply-template to install a simple lifecycle rule.")
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
