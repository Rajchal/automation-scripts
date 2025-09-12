#!/usr/bin/env python3
"""
aws-unused-elastic-ip-auditor.py

Purpose:
  Enumerate Elastic IP addresses (EIPs) that are currently unattached to any
  network interface or instance (public IPv4) and optionally release them to
  avoid unnecessary hourly charges.

Features:
  - Multi-region scanning
  - Detects EIPs with no AssociationId (classic or VPC) -> UNUSED
  - Optional tag exclusion (--exclude-tag Key=Value) to keep reserved addresses
  - Dry-run by default; --release performs release
  - JSON output option
  - Summarizes potential monthly cost waste estimate (assumes $3.60/mo per unused static IPv4, ~ $0.005/hr)

Safety:
  - Will NOT release if tagged with any exclude-tag provided
  - Only releases addresses classified as UNUSED

Permissions Needed:
  - ec2:DescribeAddresses, ec2:ReleaseAddress, ec2:DescribeRegions

Examples:
  python aws-unused-elastic-ip-auditor.py --regions us-east-1 us-west-2
  python aws-unused-elastic-ip-auditor.py --profile prod --exclude-tag Keep=true --release --json

Exit Codes:
  0 success
  1 unexpected error
"""
import argparse
import boto3
import json
import sys
from typing import List, Dict, Any, Optional

COST_MONTHLY_PER_EIP = 3.60  # approximate


def parse_args():
    p = argparse.ArgumentParser(description="Audit unused Elastic IPs (dry-run)")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all enabled)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--exclude-tag", action="append", help="Key=Value tag pair to exclude from release (can repeat)")
    p.add_argument("--release", action="store_true", help="Actually release unused addresses")
    p.add_argument("--max-release", type=int, default=100, help="Max EIPs to release this run")
    p.add_argument("--json", action="store_true", help="JSON output")
    return p.parse_args()


def session(profile: Optional[str]):
    if profile:
        return boto3.Session(profile_name=profile)
    return boto3.Session()


def discover_regions(sess, explicit: Optional[List[str]]):
    if explicit:
        return explicit
    try:
        ec2 = sess.client("ec2")
        resp = ec2.describe_regions(AllRegions=False)
        return sorted(r["RegionName"] for r in resp["Regions"])
    except Exception:
        return ["us-east-1"]


def parse_exclude(ex: Optional[List[str]]) -> Dict[str, str]:
    out = {}
    if not ex:
        return out
    for item in ex:
        if "=" not in item:
            continue
        k, v = item.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def addr_tags(addr: Dict[str, Any]) -> Dict[str, str]:
    return {t['Key']: t['Value'] for t in addr.get('Tags', [])}


def matches_exclude(addr: Dict[str, Any], exclude: Dict[str, str]) -> bool:
    if not exclude:
        return False
    tags = addr_tags(addr)
    for k, v in exclude.items():
        if tags.get(k) == v:
            return True
    return False


def release_address(ec2, alloc_id: str) -> Optional[str]:
    try:
        ec2.release_address(AllocationId=alloc_id)
        return None
    except Exception as e:
        return str(e)


def main():
    args = parse_args()
    sess = session(args.profile)
    regs = discover_regions(sess, args.regions)
    exclude = parse_exclude(args.exclude_tag)

    results = []
    total_unused = 0
    total_release_attempt = 0
    total_released = 0

    for region in regs:
        ec2 = sess.client("ec2", region_name=region)
        try:
            resp = ec2.describe_addresses()
        except Exception as e:
            print(f"WARN region {region} describe_addresses failed: {e}", file=sys.stderr)
            continue
        for addr in resp.get("Addresses", []):
            alloc_id = addr.get("AllocationId")
            public_ip = addr.get("PublicIp")
            assoc = addr.get("AssociationId")
            network_border = addr.get("NetworkBorderGroup")
            network_intf = addr.get("NetworkInterfaceId")
            domain = addr.get("Domain")  # vpc or standard
            tags = addr_tags(addr)
            status = "IN_USE" if assoc or network_intf else "UNUSED"
            excluded = matches_exclude(addr, exclude)
            rec = {
                "region": region,
                "allocation_id": alloc_id,
                "public_ip": public_ip,
                "status": status,
                "excluded": excluded,
                "domain": domain,
                "network_border_group": network_border,
                "tags": tags,
                "release_attempted": False,
                "release_error": None,
            }
            if status == "UNUSED":
                total_unused += 1
                if not excluded:
                    if args.release and total_release_attempt < args.max_release:
                        err = release_address(ec2, alloc_id)
                        rec["release_attempted"] = True
                        rec["release_error"] = err
                        total_release_attempt += 1
                        if not err:
                            total_released += 1
            results.append(rec)

    wasted_monthly = (total_unused - total_released) * COST_MONTHLY_PER_EIP

    if args.json:
        print(json.dumps({
            "regions": regs,
            "release": args.release,
            "unused_total": total_unused,
            "released": total_released,
            "estimated_monthly_waste_after_run": round(wasted_monthly, 2),
            "exclude_tags": exclude,
            "results": results,
        }, indent=2))
        return 0

    unused_rows = [r for r in results if r['status'] == 'UNUSED']
    if not unused_rows:
        print("No unused Elastic IPs detected.")
        return 0

    header = ["Region", "AllocationId", "PublicIp", "Excluded", "Released"]
    rows = [header]
    for r in unused_rows:
        rows.append([
            r["region"], r["allocation_id"], r["public_ip"], str(r["excluded"]),
            "Y" if r["release_attempted"] and not r["release_error"] else ("ERR" if r["release_error"] else "N")
        ])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = "  ".join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print("  ".join("-" * w for w in widths))
        else:
            print(line)
    if not args.release:
        print("\nDry-run only. Use --release to free unused addresses.")
    if wasted_monthly > 0:
        print(f"Estimated monthly waste (remaining unused): ${wasted_monthly:.2f}")
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
