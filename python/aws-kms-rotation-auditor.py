#!/usr/bin/env python3
"""
aws-kms-rotation-auditor.py

Purpose:
  Audit AWS KMS customer-managed keys (CMKs) for rotation best practices and optionally enable
  rotation for eligible keys. Rotation is only supported for symmetric customer-managed keys.

Features:
  - Multi-region scan (default: all enabled regions)
  - Filters:
      * --include-asymmetric (by default only symmetric keys are considered)
      * --required-tag Key=Value (repeatable)
      * --name-filter substring to match in the key description or alias
  - Optional --enable-rotation to turn on rotation for eligible keys (safe operation)
  - --max-apply to cap changes per run
  - JSON or human-readable output

Safety:
  - Read-only by default; enabling rotation is idempotent and supported only for
    CUSTOMER-managed, ENABLED, symmetric keys.

Permissions:
  - kms:ListKeys, kms:DescribeKey, kms:GetKeyRotationStatus, kms:EnableKeyRotation, kms:ListResourceTags
  - ec2:DescribeRegions (for region discovery)

Examples:
  python aws-kms-rotation-auditor.py --regions us-east-1 us-west-2 --json
  python aws-kms-rotation-auditor.py --enable-rotation --max-apply 20

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
    p = argparse.ArgumentParser(description="Audit/enable KMS key rotation (dry-run by default)")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all enabled)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--include-asymmetric", action="store_true", help="Include asymmetric keys (rotation unsupported but will report)")
    p.add_argument("--required-tag", action="append", help="Filter to keys with Tag Key=Value (repeat)")
    p.add_argument("--name-filter", help="Substring to match in key description or alias")
    p.add_argument("--enable-rotation", action="store_true", help="Enable rotation for eligible keys")
    p.add_argument("--max-apply", type=int, default=100, help="Max keys to modify")
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


def list_keys(kms):
    keys = []
    token = None
    while True:
        kwargs = {}
        if token:
            kwargs["NextToken"] = token
        resp = kms.list_keys(**kwargs)
        keys.extend(resp.get("Keys", []))
        token = resp.get("NextToken")
        if not token:
            break
    return keys


def key_tags(kms, key_id: str) -> Dict[str, str]:
    try:
        token = None
        tags = []
        while True:
            kwargs = {"KeyId": key_id}
            if token:
                kwargs["NextToken"] = token
            resp = kms.list_resource_tags(**kwargs)
            tags.extend(resp.get("Tags", []))
            token = resp.get("NextMarker")
            if not token:
                break
        return {t.get("TagKey"): t.get("TagValue") for t in tags}
    except Exception:
        return {}


def key_aliases(kms, key_id: str) -> List[str]:
    aliases = []
    try:
        token = None
        while True:
            kwargs = {}
            if token:
                kwargs["NextToken"] = token
            resp = kms.list_aliases(**kwargs)
            for a in resp.get("Aliases", []):
                if a.get("TargetKeyId") == key_id:
                    if a.get("AliasName"):
                        aliases.append(a["AliasName"])
            token = resp.get("NextToken")
            if not token:
                break
    except Exception:
        pass
    return aliases


def eligible_for_rotation(md: Dict[str, Any], include_asymmetric: bool) -> bool:
    if md.get("KeyManager") != "CUSTOMER":
        return False
    if md.get("KeyState") != "Enabled":
        return False
    spec = md.get("KeySpec") or ""
    if spec.startswith("SYMMETRIC_"):
        return True
    if include_asymmetric:
        # Asymmetric keys don't support rotation; treated as not eligible but still report
        return False
    return False


def get_rotation_status(kms, key_id: str) -> Optional[bool]:
    try:
        resp = kms.get_key_rotation_status(KeyId=key_id)
        return bool(resp.get("KeyRotationEnabled"))
    except Exception:
        return None


def enable_rotation(kms, key_id: str) -> Optional[str]:
    try:
        kms.enable_key_rotation(KeyId=key_id)
        return None
    except Exception as e:
        return str(e)


def main():
    args = parse_args()
    sess = session(args.profile)
    regions = discover_regions(sess, args.regions)
    needed_tags = parse_tag_filters(args.required_tag)

    results = []
    applied = 0

    for region in regions:
        kms = sess.client("kms", region_name=region)
        try:
            keys = list_keys(kms)
        except Exception as e:
            print(f"WARN region {region} list keys failed: {e}", file=sys.stderr)
            continue
        for k in keys:
            key_id = k.get("KeyId")
            try:
                desc = kms.describe_key(KeyId=key_id)
                md = desc.get("KeyMetadata", {})
            except Exception as e:
                print(f"WARN region {region} describe key {key_id} failed: {e}", file=sys.stderr)
                continue

            # Skip AWS-managed keys
            if md.get("KeyManager") != "CUSTOMER":
                continue

            # Filter by symmetric unless overridden
            spec = md.get("KeySpec") or ""
            is_symmetric = spec.startswith("SYMMETRIC_")
            if not is_symmetric and not args.include_asymmetric:
                continue

            # Name/alias filter
            aliases = key_aliases(kms, key_id)
            name_hit = False
            if args.name_filter:
                nf = args.name_filter.lower()
                d = (md.get("Description") or "").lower()
                if nf in d or any(nf in a.lower() for a in aliases):
                    name_hit = True
                else:
                    continue

            # Tag filter
            tags = key_tags(kms, key_id)
            if needed_tags:
                ok = True
                for tk, tv in needed_tags.items():
                    if tags.get(tk) != tv:
                        ok = False
                        break
                if not ok:
                    continue

            rotation_status = get_rotation_status(kms, key_id)
            is_eligible = eligible_for_rotation(md, args.include_asymmetric)

            rec = {
                "region": region,
                "key_id": key_id,
                "arn": md.get("Arn"),
                "description": md.get("Description"),
                "aliases": aliases,
                "key_manager": md.get("KeyManager"),
                "key_state": md.get("KeyState"),
                "key_spec": md.get("KeySpec"),
                "creation_date": md.get("CreationDate").isoformat() if isinstance(md.get("CreationDate"), dt.datetime) else None,
                "rotation_enabled": rotation_status,
                "eligible_for_rotation": is_eligible,
                "apply_attempted": False,
                "apply_error": None,
            }

            if args.enable_rotation and is_eligible and rotation_status is False and applied < args.max_apply:
                err = enable_rotation(kms, key_id)
                rec["apply_attempted"] = True
                rec["apply_error"] = err
                if err is None:
                    applied += 1

            # Report keys that are eligible but not rotated, or if JSON mode (full list)
            if (is_eligible and rotation_status is False) or args.json:
                results.append(rec)

    payload = {
        "regions": regions,
        "include_asymmetric": args.include_asymmetric,
        "enable_rotation": args.enable_rotation,
        "applied": applied,
        "results": results,
    }

    if args.json:
        print(json.dumps(payload, indent=2, default=str))
        return 0

    if not results:
        print("All eligible customer-managed symmetric keys already have rotation enabled (or none found).")
        return 0

    header = ["Region", "KeyId", "Aliases", "Spec", "Rotated", "Eligible", "Applied"]
    rows = [header]
    for r in results:
        rows.append([
            r["region"], r["key_id"], (",".join(r.get("aliases") or []) or "-"),
            r.get("key_spec") or "-", str(r.get("rotation_enabled")), str(r.get("eligible_for_rotation")),
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
    if not args.enable_rotation:
        print("\nDry-run. Use --enable-rotation to remediate eligible keys.")
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
