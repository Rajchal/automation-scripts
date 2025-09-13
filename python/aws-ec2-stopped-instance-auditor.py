#!/usr/bin/env python3
"""
aws-ec2-stopped-instance-auditor.py

Purpose:
  Identify EC2 instances that have remained in the 'stopped' state beyond a
  retention threshold and estimate potential monthly EBS cost if left unused.
  Optionally mark flagged instances with a tag for later cleanup workflow.

Heuristics:
  - Instance state == stopped
  - LaunchTime (or last state transition if available) older than --stopped-days

Features:
  - Multi-region scan
  - Threshold days (--stopped-days, default 14)
  - Name substring filter (--name-filter) using Name tag
  - Tag filter include (--required-tag Key=Value) repeatable
  - Optional --mark TAG=VALUE to apply to flagged instances (dry-run unless provided)
  - JSON output with per-instance volume summary and estimated monthly cost

Cost Estimation:
  - Sums gp2/gp3 standard volumes at $0.10/GB-month (simple heuristic)
  - Other volume types priced with same placeholder unless extended

Permissions Required:
  - ec2:DescribeInstances, ec2:DescribeVolumes, ec2:CreateTags, ec2:DescribeRegions

Examples:
  python aws-ec2-stopped-instance-auditor.py --regions us-east-1 us-west-2 --stopped-days 30
  python aws-ec2-stopped-instance-auditor.py --mark CleanupCandidate=1 --json

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

GB_COST = 0.10  # USD per GB-month heuristic


def parse_args():
    p = argparse.ArgumentParser(description="Audit long-stopped EC2 instances")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--stopped-days", type=int, default=14, help="Days stopped threshold")
    p.add_argument("--name-filter", help="Substring filter on Name tag")
    p.add_argument("--required-tag", action="append", help="Include only instances with Tag Key=Value (repeat)")
    p.add_argument("--mark", help="TAG=VALUE to apply to flagged instances")
    p.add_argument("--max-mark", type=int, default=200, help="Max instances to tag")
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


def parse_mark(mark: Optional[str]):
    if not mark or "=" not in mark:
        return None, None
    k, v = mark.split("=", 1)
    return k.strip(), v.strip()


def instance_name(tags: List[Dict[str, str]]):
    for t in tags or []:
        if t.get("Key") == "Name":
            return t.get("Value")
    return None


def list_instances(ec2):
    out = []
    token = None
    while True:
        kwargs = {"MaxResults": 1000}
        if token:
            kwargs["NextToken"] = token
        resp = ec2.describe_instances(**kwargs)
        for r in resp.get("Reservations", []):
            out.extend(r.get("Instances", []))
        token = resp.get("NextToken")
        if not token:
            break
    return out


def list_volumes(ec2, volume_ids: List[str]):
    if not volume_ids:
        return []
    vols = []
    for i in range(0, len(volume_ids), 200):
        chunk = volume_ids[i:i+200]
        try:
            resp = ec2.describe_volumes(VolumeIds=chunk)
        except Exception:
            continue
        vols.extend(resp.get("Volumes", []))
    return vols


def volume_cost_gb(vol: Dict[str, Any]):
    size = vol.get("Size", 0)
    return size * GB_COST


def main():
    args = parse_args()
    sess = session(args.profile)
    regs = discover_regions(sess, args.regions)
    needed_tags = parse_tag_filters(args.required_tag)
    mark_k, mark_v = parse_mark(args.mark)

    cutoff_days = args.stopped_days
    now = dt.datetime.utcnow()

    results = []
    mark_count = 0

    for region in regs:
        ec2 = sess.client("ec2", region_name=region)
        try:
            instances = list_instances(ec2)
        except Exception as e:
            print(f"WARN region {region} list instances failed: {e}", file=sys.stderr)
            continue
        # Preload all volume IDs for stopped instances to estimate cost
        volume_map = {}
        for inst in instances:
            if inst.get("State", {}).get("Name") != "stopped":
                continue
            for bd in inst.get("BlockDeviceMappings", []):
                ebs = bd.get("Ebs")
                if ebs and ebs.get("VolumeId"):
                    volume_map[ebs["VolumeId"]] = None
        volume_details = list_volumes(ec2, list(volume_map.keys()))
        for v in volume_details:
            volume_map[v.get("VolumeId")] = v

        for inst in instances:
            state = inst.get("State", {}).get("Name")
            if state != "stopped":
                continue
            tags = inst.get("Tags", [])
            name = instance_name(tags) or inst.get("InstanceId")
            if args.name_filter and args.name_filter not in (name or ""):
                continue
            # Tag filter
            tag_dict = {t['Key']: t['Value'] for t in tags}
            include = True
            for k, v in needed_tags.items():
                if tag_dict.get(k) != v:
                    include = False
                    break
            if not include:
                continue
            launch = inst.get("LaunchTime")
            if launch and launch.tzinfo:
                launch = launch.astimezone(dt.timezone.utc).replace(tzinfo=None)
            days = (now - launch).days if launch else None
            if days is not None and days < cutoff_days:
                continue
            # Collect volumes & cost
            volume_ids = [bd.get("Ebs", {}).get("VolumeId") for bd in inst.get("BlockDeviceMappings", []) if bd.get("Ebs")]
            vols = [volume_map.get(vid) for vid in volume_ids if volume_map.get(vid)]
            total_gb = sum(v.get("Size", 0) for v in vols)
            est_cost = sum(volume_cost_gb(v) for v in vols)
            rec = {
                "region": region,
                "instance_id": inst.get("InstanceId"),
                "name": name,
                "stopped_days": days,
                "volumes_gb_total": total_gb,
                "estimated_monthly_cost_usd": round(est_cost, 2),
                "mark_attempted": False,
                "mark_error": None,
            }
            if mark_k and mark_count < args.max_mark:
                try:
                    ec2.create_tags(Resources=[inst.get("InstanceId")], Tags=[{"Key": mark_k, "Value": mark_v}])
                    rec["mark_attempted"] = True
                    mark_count += 1
                except Exception as e:
                    rec["mark_attempted"] = True
                    rec["mark_error"] = str(e)
            results.append(rec)

    if args.json:
        print(json.dumps({
            "regions": regs,
            "stopped_days_threshold": cutoff_days,
            "marked": mark_count,
            "results": results,
        }, indent=2))
        return 0

    if not results:
        print("No long-stopped instances found.")
        return 0

    header = ["Region", "Instance", "StoppedDays", "GB", "EstCost", "Marked"]
    rows = [header]
    for r in results:
        rows.append([
            r["region"], r["instance_id"], r.get("stopped_days"), r.get("volumes_gb_total"), r.get("estimated_monthly_cost_usd"),
            "Y" if r["mark_attempted"] and not r["mark_error"] else ("ERR" if r["mark_error"] else "N")
        ])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = "  ".join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print("  ".join("-" * w for w in widths))
        else:
            print(line)
    if mark_k:
        print("\nTagging attempted for eligible instances.")
    else:
        print("\nDry-run only. Use --mark TAG=VALUE to tag flagged instances.")
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
