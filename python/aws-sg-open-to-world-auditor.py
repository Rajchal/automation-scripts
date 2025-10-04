#!/usr/bin/env python3
"""
aws-sg-open-to-world-auditor.py

Purpose:
  Detect Security Groups with inbound rules open to the world (0.0.0.0/0 or ::/0),
  optionally constrained to a set of sensitive ports. Can optionally revoke only
  the matching offending permissions (dry-run by default).

Features:
  - Multi-region scan
  - Sensitive ports filter (--ports) or built-in default set
  - Tag filter (--required-tag Key=Value) repeatable and name filter (--name-filter)
  - JSON output option
  - Optional --revoke to remove only offending ingress permissions
  - Cap modifications with --max-revoke

Safety:
  - Dry-run unless --revoke is provided
  - Only revokes the specific offending ipRanges/ipv6Ranges for matching ports

Permissions:
  - ec2:DescribeSecurityGroups, ec2:RevokeSecurityGroupIngress, ec2:DescribeRegions

Examples:
  python aws-sg-open-to-world-auditor.py --regions us-east-1 us-west-2 --ports 22 3389
  python aws-sg-open-to-world-auditor.py --name-filter web --json
  python aws-sg-open-to-world-auditor.py --ports 22 --revoke --max-revoke 20

Exit Codes:
  0 success
  1 unexpected error
"""
import argparse
import boto3
import json
import sys
from typing import List, Dict, Any, Optional

DEFAULT_SENSITIVE_PORTS = [22, 3389, 3306, 5432, 27017, 9200, 25]

WORLD_IPV4 = "0.0.0.0/0"
WORLD_IPV6 = "::/0"


def parse_args():
    p = argparse.ArgumentParser(description="Audit SGs open to world; optional revoke (dry-run by default)")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all enabled)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--ports", type=int, nargs="*", help=f"Ports to check (default set: {DEFAULT_SENSITIVE_PORTS})")
    p.add_argument("--name-filter", help="Substring filter on security group name or id")
    p.add_argument("--required-tag", action="append", help="Key=Value tag filter include (repeat)")
    p.add_argument("--json", action="store_true", help="JSON output")
    p.add_argument("--revoke", action="store_true", help="Revoke offending permissions")
    p.add_argument("--max-revoke", type=int, default=100, help="Max revoke operations to attempt")
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


def sg_tags_dict(group: Dict[str, Any]):
    return {t['Key']: t['Value'] for t in group.get('Tags', [])}


def matches_required(group: Dict[str, Any], needed: Dict[str, str]):
    if not needed:
        return True
    tags = sg_tags_dict(group)
    for k, v in needed.items():
        if tags.get(k) != v:
            return False
    return True


def list_security_groups(ec2):
    out = []
    token = None
    while True:
        kwargs = {}
        if token:
            kwargs["NextToken"] = token
        resp = ec2.describe_security_groups(**kwargs)
        out.extend(resp.get("SecurityGroups", []))
        token = resp.get("NextToken")
        if not token:
            break
    return out


def is_world(range_item: Dict[str, Any]) -> bool:
    cidr = range_item.get('CidrIp') or range_item.get('CidrIpv6')
    return cidr in (WORLD_IPV4, WORLD_IPV6)


def port_in_rule(from_p: Optional[int], to_p: Optional[int], target_ports: List[int]) -> bool:
    # For protocols that are '-1' (all), treat as matching any target port
    if from_p is None and to_p is None:
        return True
    for tp in target_ports:
        if from_p is None or to_p is None:
            return True
        if from_p <= tp <= to_p:
            return True
    return False


def build_revoke_permission(ip_perm: Dict[str, Any], offender_ranges: List[Dict[str, Any]]):
    # Only include the offending ranges in the revoke request
    perm = {
        'IpProtocol': ip_perm.get('IpProtocol'),
        'FromPort': ip_perm.get('FromPort'),
        'ToPort': ip_perm.get('ToPort'),
    }
    ipv4 = [r for r in offender_ranges if 'CidrIp' in r]
    ipv6 = [r for r in offender_ranges if 'CidrIpv6' in r]
    if ipv4:
        perm['IpRanges'] = ipv4
    if ipv6:
        perm['Ipv6Ranges'] = ipv6
    return perm


def main():
    args = parse_args()
    sess = session(args.profile)
    regs = discover_regions(sess, args.regions)
    target_ports = args.ports or DEFAULT_SENSITIVE_PORTS
    needed_tags = parse_tag_filters(args.required_tag)

    findings = []
    revoke_ops = 0

    for region in regs:
        ec2 = sess.client('ec2', region_name=region)
        try:
            groups = list_security_groups(ec2)
        except Exception as e:
            print(f"WARN region {region} describe_security_groups failed: {e}", file=sys.stderr)
            continue
        for sg in groups:
            sg_id = sg.get('GroupId')
            sg_name = sg.get('GroupName')
            if args.name_filter and (args.name_filter not in sg_name and args.name_filter not in sg_id):
                continue
            if not matches_required(sg, needed_tags):
                continue
            offending = []
            for perm in sg.get('IpPermissions', []):
                proto = perm.get('IpProtocol')
                from_p = perm.get('FromPort')
                to_p = perm.get('ToPort')
                # For non-TCP/UDP or all protocols, still treat as risky if world-open
                if proto not in ('tcp', 'udp', '-1'):
                    continue
                if not port_in_rule(from_p, to_p, target_ports):
                    continue
                world_ipv4 = [r for r in perm.get('IpRanges', []) if is_world(r)]
                world_ipv6 = [r for r in perm.get('Ipv6Ranges', []) if is_world(r)]
                if world_ipv4 or world_ipv6:
                    offending.append({
                        'permission': perm,
                        'world_ipv4': world_ipv4,
                        'world_ipv6': world_ipv6,
                    })
            if not offending:
                continue
            rec = {
                'region': region,
                'group_id': sg_id,
                'group_name': sg_name,
                'offenses': []
            }
            for off in offending:
                perm = off['permission']
                from_p = perm.get('FromPort')
                to_p = perm.get('ToPort')
                offender_ranges = []
                offender_ranges.extend(off['world_ipv4'])
                offender_ranges.extend(off['world_ipv6'])
                rec['offenses'].append({
                    'ip_protocol': perm.get('IpProtocol'),
                    'from_port': from_p,
                    'to_port': to_p,
                    'ranges': [r.get('CidrIp') or r.get('CidrIpv6') for r in offender_ranges]
                })
                if args.revoke and revoke_ops < args.max_revoke:
                    perm_to_revoke = build_revoke_permission(perm, offender_ranges)
                    try:
                        ec2.revoke_security_group_ingress(GroupId=sg_id, IpPermissions=[perm_to_revoke])
                        revoke_ops += 1
                    except Exception as e:
                        # record failure as a pseudo offense note
                        rec.setdefault('revoke_errors', []).append(str(e))
            findings.append(rec)

    if args.json:
        print(json.dumps({
            'regions': regs,
            'ports': target_ports,
            'revoke': args.revoke,
            'findings': findings,
        }, indent=2))
        return 0

    if not findings:
        print("No world-open security group rules detected for selected ports.")
        return 0

    header = ["Region", "GroupId", "Name", "Offenses"]
    rows = [header]
    for f in findings:
        offense_summ = []
        for o in f['offenses']:
            rng = "/".join([str(o.get('from_port')), str(o.get('to_port'))])
            offense_summ.append(f"{o['ip_protocol']}:{rng} -> {','.join(o['ranges'])}")
        rows.append([f['region'], f['group_id'], f['group_name'], '; '.join(offense_summ)])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = "  ".join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print("  ".join("-" * w for w in widths))
        else:
            print(line)
    if not args.revoke:
        print("\nDry-run only. Use --revoke to remove offending world-open ranges for matching ports.")
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
