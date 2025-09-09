#!/usr/bin/env python3
"""
AWS Security Group Unused Ingress Auditor

Purpose:
  Identify Security Group ingress rules (IPv4 / IPv6 or referenced SGs) that appear unused
  because no current Elastic Network Interface (ENI) traffic potential exists for those ports.

Heuristic Logic:
  1. Collect all ENIs with their attached Security Groups and primary private IPs.
  2. Build a mapping SG -> set of ENI ids using it.
  3. For each SG ingress rule, determine (protocol, port range, CIDR/source SG list).
  4. A rule is considered potentially unused if:
       - No ENI currently attached to the SG (entire SG unused) OR
       - Protocol/port range isn't matched by any port exposed by listening processes (optional future enhancement) OR
       - (Simplified) No ENI -> treat each rule as unused (phase 1 implementation)

Current Implementation (Phase 1):
  Flags SGs with zero attachments and lists their ingress rules.
  Future extension could integrate VPC Flow Logs or CloudWatch metrics to validate real traffic.

Output Columns:
  GroupId  Name  Reason  RuleSummary

Options:
  --region <region>
  --profile <profile>
  --json for JSON output
  --include-attached to also list attached SGs with empty ingress rule sets

Exit Codes:
  0 success
  1 AWS api error

Limitations:
  - Does not yet parse listening ports nor flow logs; focuses on orphan SGs.
  - Use with caution; always verify before deleting rules.
"""
from __future__ import annotations
import argparse
import json
import sys
import boto3
from botocore.exceptions import BotoCoreError, ClientError


def parse_args():
    p = argparse.ArgumentParser(description="Audit potentially unused SG ingress rules")
    p.add_argument('--region', help='AWS region')
    p.add_argument('--profile', help='AWS profile')
    p.add_argument('--json', action='store_true', help='JSON output')
    p.add_argument('--include-attached', action='store_true', help='Also list attached SGs that have zero ingress rules')
    return p.parse_args()


def session_client(service: str, profile: str | None, region: str | None):
    session_args = {}
    if profile:
        session_args['profile_name'] = profile
    session = boto3.Session(**session_args) if session_args else boto3.Session()
    return session.client(service, region_name=region) if region else session.client(service)


def gather_security_groups(ec2):
    groups = []
    paginator = ec2.get_paginator('describe_security_groups')
    for page in paginator.paginate():
        groups.extend(page.get('SecurityGroups', []))
    return groups


def gather_enis(ec2):
    enis = []
    paginator = ec2.get_paginator('describe_network_interfaces')
    for page in paginator.paginate():
        enis.extend(page.get('NetworkInterfaces', []))
    return enis


def build_attachment_map(enis):
    sg_to_enis = {}
    for eni in enis:
        for group in eni.get('Groups', []):
            sg_to_enis.setdefault(group['GroupId'], set()).add(eni['NetworkInterfaceId'])
    return sg_to_enis


def summarize_rule(rule):
    proto = rule.get('IpProtocol')
    if proto == '-1':
        proto = 'ALL'
    from_port = rule.get('FromPort')
    to_port = rule.get('ToPort')
    port_repr = 'all'
    if from_port is not None and to_port is not None:
        port_repr = f"{from_port}" if from_port == to_port else f"{from_port}-{to_port}"
    ip_ranges = [r.get('CidrIp') for r in rule.get('IpRanges', [])]
    ip6_ranges = [r.get('CidrIpv6') for r in rule.get('Ipv6Ranges', [])]
    sg_refs = [r.get('GroupId') for r in rule.get('UserIdGroupPairs', [])]
    parts = [proto, port_repr]
    if ip_ranges:
        parts.append('v4:' + ','.join(ip_ranges))
    if ip6_ranges:
        parts.append('v6:' + ','.join(ip6_ranges))
    if sg_refs:
        parts.append('sg:' + ','.join(sg_refs))
    return '|'.join(parts)


def audit(groups, sg_to_enis, include_attached: bool):
    findings = []
    for g in groups:
        gid = g['GroupId']
        attached = gid in sg_to_enis
        ingress = g.get('IpPermissions', [])
        if not attached:
            # Entire SG unused
            if ingress:
                for rule in ingress:
                    findings.append({
                        'GroupId': gid,
                        'GroupName': g.get('GroupName'),
                        'Reason': 'sg-unattached',
                        'Rule': summarize_rule(rule)
                    })
            else:
                findings.append({
                    'GroupId': gid,
                    'GroupName': g.get('GroupName'),
                    'Reason': 'sg-unattached-empty',
                    'Rule': ''
                })
        elif include_attached and not ingress:
            findings.append({
                'GroupId': gid,
                'GroupName': g.get('GroupName'),
                'Reason': 'attached-no-ingress',
                'Rule': ''
            })
    return findings


def main():
    args = parse_args()
    try:
        ec2 = session_client('ec2', args.profile, args.region)
        groups = gather_security_groups(ec2)
        enis = gather_enis(ec2)
        sg_to_enis = build_attachment_map(enis)
        findings = audit(groups, sg_to_enis, args.include_attached)
        if args.json:
            print(json.dumps({'findings': findings, 'count': len(findings)}, indent=2))
            return
        if not findings:
            print('No potentially unused security group ingress rules found.')
            return
        print('# Potentially unused SG ingress rules (verify before modifying)')
        for f in findings:
            print(f"{f['GroupId']} {f['GroupName']} {f['Reason']} {f['Rule']}")
        print('\nCleanup suggestions (double-check):')
        for f in findings[:20]:
            print(f"  aws ec2 delete-security-group --group-id {f['GroupId']}  # if safe and truly unused")
        if len(findings) > 20:
            print(f"  ... {len(findings)-20} more")
    except (BotoCoreError, ClientError) as e:
        print(f"AWS Error: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()
