#!/usr/bin/env python3
"""
AWS ACM Certificate Expiry Detector

Lists expired and soon-to-expire (<= threshold days) ACM certificates across one
or multiple regions and optionally prints SNS publish commands for alerts.

Features:
  - Multi-region scan (provide comma list or --all-regions)
  - Filters by tag key/value if desired
  - JSON or human output
  - Suggests renewal steps for imported vs Amazon-issued certs

Usage:
  python expired-acm-cert-detector.py --regions us-east-1,us-west-2 --days 30
  python expired-acm-cert-detector.py --all-regions --json --profile prod
  python expired-acm-cert-detector.py --regions eu-central-1 --tag Key=Environment,Value=prod

Exit Codes:
  0 success
  1 AWS error

Permissions Needed:
  acm:ListCertificates
  acm:DescribeCertificate
  ec2:DescribeRegions (if --all-regions)
  (Optional) sns:Publish if you use suggested commands
"""
from __future__ import annotations
import argparse
import boto3
import json
import sys
import datetime as dt
from botocore.exceptions import BotoCoreError, ClientError


def parse_args():
    p = argparse.ArgumentParser(description="Detect expiring / expired ACM certificates")
    p.add_argument('--regions', help='Comma list of regions to scan')
    p.add_argument('--all-regions', action='store_true', help='Scan all enabled regions')
    p.add_argument('--profile', help='AWS profile')
    p.add_argument('--days', type=int, default=30, help='Threshold days until expiry (default 30)')
    p.add_argument('--tag', action='append', help='Filter tag in form Key=Environment,Value=prod (can repeat)')
    p.add_argument('--json', action='store_true', help='JSON output')
    return p.parse_args()


def session(profile: str | None):
    if profile:
        return boto3.Session(profile_name=profile)
    return boto3.Session()


def list_regions(sess, explicit: str | None, all_regions: bool):
    if explicit:
        return [r.strip() for r in explicit.split(',') if r.strip()]
    if all_regions:
        ec2 = sess.client('ec2')
        resp = ec2.describe_regions(AllRegions=False)
        return [r['RegionName'] for r in resp['Regions']]
    # fallback to session region or common default
    return [sess.region_name or 'us-east-1']


def parse_tag_filters(tag_args):
    filters = []
    if not tag_args:
        return filters
    for t in tag_args:
        parts = t.split(',')
        kv = {}
        for part in parts:
            if '=' in part:
                k, v = part.split('=',1)
                kv[k.strip()] = v.strip()
        if kv:
            filters.append(kv)
    return filters


def certificate_matches_tags(cert_detail, tag_filters):
    if not tag_filters:
        return True
    tags = {t['Key']: t['Value'] for t in cert_detail.get('Tags', [])}
    for f in tag_filters:
        # require all key=val in this filter set to match
        if all(tags.get(k) == v for k, v in f.items()):
            return True
    return False


def gather_acm(sess, region: str, tag_filters, threshold_days: int):
    acm = sess.client('acm', region_name=region)
    paginator = acm.get_paginator('list_certificates')
    summary = []
    now = dt.datetime.utcnow().replace(tzinfo=dt.timezone.utc)
    for page in paginator.paginate(CertificateStatuses=['ISSUED','EXPIRED','INACTIVE']):
        for cert in page.get('CertificateSummaryList', []):
            arn = cert['CertificateArn']
            try:
                detail = acm.describe_certificate(CertificateArn=arn)['Certificate']
                # include tags
                tags_resp = acm.list_tags_for_certificate(CertificateArn=arn)
                detail['Tags'] = tags_resp.get('Tags', [])
            except (BotoCoreError, ClientError):
                continue
            if not certificate_matches_tags(detail, tag_filters):
                continue
            not_after = detail.get('NotAfter')
            if not not_after:
                continue
            expiry = not_after if not_after.tzinfo else not_after.replace(tzinfo=dt.timezone.utc)
            days_left = (expiry - now).days
            status = detail.get('Status')
            if days_left <= threshold_days or status == 'EXPIRED':
                summary.append({
                    'region': region,
                    'domain': detail.get('DomainName'),
                    'arn': arn,
                    'status': status,
                    'days_left': days_left,
                    'type': 'imported' if detail.get('Type') == 'IMPORTED' else 'amazon-issued',
                    'subject_alt_names': detail.get('SubjectAlternativeNames', [])[:5],
                })
    return summary


def main():
    args = parse_args()
    sess = session(args.profile)
    tag_filters = parse_tag_filters(args.tag)
    try:
        regions = list_regions(sess, args.regions, args.all_regions)
        all_findings = []
        for r in regions:
            findings = gather_acm(sess, r, tag_filters, args.days)
            all_findings.extend(findings)
        if args.json:
            print(json.dumps({'findings': all_findings, 'count': len(all_findings)}, indent=2))
            return
        if not all_findings:
            print('No expiring or expired certificates within threshold.')
            return
        print('# Expiring / Expired ACM Certificates')
        for f in all_findings:
            print(f"{f['region']} {f['domain']} {f['status']} {f['days_left']}d {f['type']} {f['arn']}")
        print('\nSuggested actions:')
        for f in all_findings[:15]:
            if f['type'] == 'amazon-issued':
                print(f"  Request renewal in console or ensure DNS validation records still present for {f['domain']}")
            else:
                print(f"  Replace imported cert for {f['domain']} (ARN {f['arn']})")
        if len(all_findings) > 15:
            print(f"  ... {len(all_findings)-15} more")
    except (BotoCoreError, ClientError) as e:
        print(f"AWS Error: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()
