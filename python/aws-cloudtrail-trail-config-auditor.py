#!/usr/bin/env python3
"""
aws-cloudtrail-trail-config-auditor.py

Purpose:
  Audit AWS CloudTrail trails for best practices and misconfigurations:
  - Not multi-region
  - Not logging management events
  - Not enabled
  - Not encrypted with KMS
  - Not sending to S3 or S3 bucket not versioned
  - Not sending to CloudWatch Logs
  - Not log file validation enabled

Features:
  - Multi-region scan
  - JSON output option
  - Name filter (--name-filter)
  - Tag filter (--required-tag Key=Value) repeatable

Permissions Required:
  - cloudtrail:DescribeTrails, cloudtrail:GetTrailStatus, cloudtrail:GetEventSelectors, cloudtrail:ListTags, s3:GetBucketVersioning

Examples:
  python aws-cloudtrail-trail-config-auditor.py --profile prod --json
  python aws-cloudtrail-trail-config-auditor.py --name-filter audit --required-tag Env=prod

Exit Codes:
  0 success
  1 error
"""
import argparse
import boto3
import json
import sys
from typing import List, Dict, Any, Optional


def parse_args():
    p = argparse.ArgumentParser(description="Audit CloudTrail trail configuration best practices")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--name-filter", help="Substring filter on trail name")
    p.add_argument("--required-tag", action="append", help="Tag filter Key=Value (repeat)")
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


def matches_tags(trail_tags: Dict[str, str], needed: Dict[str, str]):
    for k, v in needed.items():
        if trail_tags.get(k) != v:
            return False
    return True


def get_trail_tags(client, arn: str):
    try:
        resp = client.list_tags(ResourceIdList=[arn])
        tags = resp.get('ResourceTagList', [{}])[0].get('TagsList', [])
        return {t['Key']: t['Value'] for t in tags}
    except Exception:
        return {}


def get_bucket_versioning(s3, bucket: str):
    try:
        resp = s3.get_bucket_versioning(Bucket=bucket)
        return resp.get('Status') == 'Enabled'
    except Exception:
        return False


def main():
    args = parse_args()
    sess = session(args.profile)
    ct = sess.client('cloudtrail')
    s3 = sess.client('s3')
    needed_tags = parse_tag_filters(args.required_tag)

    try:
        trails = ct.describe_trails()['trailList']
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    results = []
    for t in trails:
        name = t.get('Name')
        arn = t.get('TrailARN')
        if args.name_filter and args.name_filter not in name:
            continue
        tags = get_trail_tags(ct, arn)
        if needed_tags and not matches_tags(tags, needed_tags):
            continue
        status = ct.get_trail_status(Name=name)
        selectors = ct.get_event_selectors(TrailName=name)
        findings = []
        if not t.get('IsMultiRegionTrail'):
            findings.append('NOT_MULTI_REGION')
        if not t.get('LogFileValidationEnabled'):
            findings.append('NO_LOG_FILE_VALIDATION')
        if not t.get('KmsKeyId'):
            findings.append('NO_KMS_ENCRYPTION')
        if not t.get('CloudWatchLogsLogGroupArn'):
            findings.append('NO_CLOUDWATCH_LOGS')
        if not t.get('S3BucketName'):
            findings.append('NO_S3_BUCKET')
        else:
            if not get_bucket_versioning(s3, t['S3BucketName']):
                findings.append('S3_BUCKET_NOT_VERSIONED')
        if not status.get('IsLogging'):
            findings.append('NOT_LOGGING')
        # Check event selectors for management events
        mgmt_events = False
        for sel in selectors.get('EventSelectors', []):
            if sel.get('IncludeManagementEvents'):
                mgmt_events = True
        if not mgmt_events:
            findings.append('NO_MANAGEMENT_EVENTS')
        rec = {
            'name': name,
            'arn': arn,
            'findings': findings,
            'tags': tags,
            'is_logging': status.get('IsLogging'),
            'multi_region': t.get('IsMultiRegionTrail'),
            'log_file_validation': t.get('LogFileValidationEnabled'),
            'kms_key_id': t.get('KmsKeyId'),
            'cloudwatch_logs': t.get('CloudWatchLogsLogGroupArn'),
            's3_bucket': t.get('S3BucketName'),
            's3_bucket_versioned': get_bucket_versioning(s3, t['S3BucketName']) if t.get('S3BucketName') else None,
        }
        results.append(rec)

    if args.json:
        print(json.dumps({'results': results}, indent=2))
        return 0

    if not results:
        print('No CloudTrail trails found.')
        return 0

    header = ["Name", "Findings"]
    rows = [header]
    for r in results:
        rows.append([r['name'], ','.join(r['findings'])])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = '  '.join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print('  '.join('-' * w for w in widths))
        else:
            print(line)
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
