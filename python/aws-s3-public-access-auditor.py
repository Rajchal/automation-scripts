#!/usr/bin/env python3
"""
aws-s3-public-access-auditor.py

Purpose:
  Audit S3 buckets for potential public exposure via bucket ACLs, bucket policy
  statements, or absence of recommended Block Public Access configuration.
  Optionally apply block public access settings.

Checks (flagged reasons):
  - ACL_PUBLIC: Grants with URI containing AllUsers or AuthenticatedUsers
  - POLICY_PUBLIC: Bucket policy statement Principal "*" with Effect Allow and non-restricted conditions
  - NO_BLOCK_PUBLIC: Bucket-level block public access not fully enabled

Features:
  - Account-wide bucket enumeration (single region concept; S3 global)
  - Name filter (--name-filter substring) and tag filter (--required-tag Key=Value) repeatable
  - Optional --apply-block to enable block public access (all four flags)
  - JSON output option
  - Limit changes via --max-apply

Permissions Required:
  - s3:ListAllMyBuckets, s3:GetBucketAcl, s3:GetBucketPolicy, s3:GetPublicAccessBlock,
    s3:PutPublicAccessBlock, s3:GetBucketTagging

Exit Codes:
  0 success
  1 error

Examples:
  python aws-s3-public-access-auditor.py --profile prod
  python aws-s3-public-access-auditor.py --apply-block --json --required-tag Sensitivity=public
"""
import argparse
import boto3
import json
import sys
from typing import Dict, Any, List, Optional

BLOCK_FIELDS = [
    "BlockPublicAcls",
    "IgnorePublicAcls",
    "BlockPublicPolicy",
    "RestrictPublicBuckets",
]


def parse_args():
    p = argparse.ArgumentParser(description="Audit S3 public exposure (dry-run)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--name-filter", help="Substring filter on bucket name")
    p.add_argument("--required-tag", action="append", help="Key=Value tag filter to include buckets (repeat)")
    p.add_argument("--apply-block", action="store_true", help="Apply full block public access to flagged buckets")
    p.add_argument("--max-apply", type=int, default=50, help="Max buckets to modify")
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


def bucket_tags(s3, name: str):
    try:
        resp = s3.get_bucket_tagging(Bucket=name)
        return {t['Key']: t['Value'] for t in resp.get('TagSet', [])}
    except Exception:
        return {}


def matches_tags(s3, name: str, needed: Dict[str, str]):
    if not needed:
        return True
    tags = bucket_tags(s3, name)
    for k, v in needed.items():
        if tags.get(k) != v:
            return False
    return True


def bucket_acl_public(s3, name: str) -> bool:
    try:
        acl = s3.get_bucket_acl(Bucket=name)
    except Exception:
        return False
    for g in acl.get('Grants', []):
        gr = g.get('Grantee', {})
        uri = gr.get('URI', '')
        if 'AllUsers' in uri or 'AuthenticatedUsers' in uri:
            return True
    return False


def bucket_policy_public(s3, name: str) -> bool:
    import json as _json
    try:
        pol = s3.get_bucket_policy(Bucket=name)
        doc = _json.loads(pol.get('Policy', '{}'))
    except Exception:
        return False
    for stmt in doc.get('Statement', []):
        if stmt.get('Effect') != 'Allow':
            continue
        principal = stmt.get('Principal')
        if principal == '*' or (isinstance(principal, dict) and principal.get('AWS') == '*'):
            # Basic restrictor checks
            if 'Condition' not in stmt:
                return True
            cond = stmt['Condition']
            # If condition looks restrictive (e.g., aws:SourceVpce or aws:SourceIp) we skip flagging
            restrictive_keys = {'aws:SourceIp', 'aws:SourceVpce', 'aws:PrincipalOrgID'}
            flat_keys = {k.lower() for k in cond.keys()}
            if not any(rk.lower() in flat_keys for rk in restrictive_keys):
                return True
    return False


def bucket_block_state(s3, name: str):
    try:
        resp = s3.get_public_access_block(Bucket=name)
        return resp.get('PublicAccessBlockConfiguration', {})
    except Exception:
        return {}


def block_missing(block_cfg: Dict[str, Any]):
    for f in BLOCK_FIELDS:
        if not block_cfg.get(f, False):
            return True
    return False


def apply_block(s3, name: str) -> Optional[str]:
    try:
        s3.put_public_access_block(
            Bucket=name,
            PublicAccessBlockConfiguration={
                'BlockPublicAcls': True,
                'IgnorePublicAcls': True,
                'BlockPublicPolicy': True,
                'RestrictPublicBuckets': True
            }
        )
        return None
    except Exception as e:
        return str(e)


def main():
    args = parse_args()
    sess = session(args.profile)
    s3 = sess.client('s3')
    needed = parse_tag_filters(args.required_tag)

    buckets_resp = s3.list_buckets()
    buckets = buckets_resp.get('Buckets', [])

    results = []
    apply_count = 0

    for b in buckets:
        name = b.get('Name')
        if args.name_filter and args.name_filter not in name:
            continue
        if not matches_tags(s3, name, needed):
            continue
        reasons = []
        acl_pub = bucket_acl_public(s3, name)
        pol_pub = bucket_policy_public(s3, name)
        block_cfg = bucket_block_state(s3, name)
        no_block = block_missing(block_cfg)
        if acl_pub:
            reasons.append('ACL_PUBLIC')
        if pol_pub:
            reasons.append('POLICY_PUBLIC')
        if no_block:
            reasons.append('NO_BLOCK_PUBLIC')
        if not reasons:
            continue
        rec = {
            'bucket': name,
            'creation_date': str(b.get('CreationDate')),
            'reasons': reasons,
            'block_state': block_cfg,
            'apply_attempted': False,
            'apply_error': None,
            'applied': False,
        }
        if args.apply_block and no_block and apply_count < args.max_apply:
            err = apply_block(s3, name)
            rec['apply_attempted'] = True
            rec['apply_error'] = err
            rec['applied'] = err is None
            apply_count += 1
        results.append(rec)

    if args.json:
        print(json.dumps({
            'total_buckets': len(buckets),
            'flagged': len(results),
            'apply_block': args.apply_block,
            'results': results,
        }, indent=2))
        return 0

    if not results:
        print('No publicly exposed buckets under current heuristics.')
        return 0

    header = ["Bucket", "Reasons", "Applied"]
    rows = [header]
    for r in results:
        rows.append([r['bucket'], ','.join(r['reasons']), 'Y' if r['applied'] else ('ERR' if r['apply_error'] else 'N')])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = '  '.join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print('  '.join('-' * w for w in widths))
        else:
            print(line)
    if not args.apply_block:
        print('\nDry-run only. Use --apply-block to enable S3 Block Public Access on flagged buckets.')
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
