#!/usr/bin/env python3
"""
aws-opensearch-idle-domain-auditor.py

Purpose:
  Identify potentially idle or under-utilized OpenSearch/Elasticsearch domains across regions using
  CloudWatch metrics. Optionally tag flagged domains for review. This does NOT delete domains.

Features:
  - Multi-region scan (default: all enabled)
  - CloudWatch metrics window (default 14 days) and period (default 3600s)
  - Thresholds (idle when all satisfied):
      * --min-requests (Sum of HTTPRequests) default: 10
      * --max-cpu-avg (Average CPUUtilization) default: 5.0
      * --max-jvm-avg (Average JVMMemoryPressure) default: 75.0
  - Reports min FreeStorageSpace (GB) for awareness
  - Optional tagging with --apply-tag and safety cap --max-apply
  - JSON or human-readable output

Notes & Safety:
  - Tagging is metadata-only and safe. No deletes or config changes are performed.
  - CloudWatch namespace is AWS/ES for both legacy Elasticsearch and OpenSearch.

Permissions:
  - opensearch:ListDomainNames, opensearch:DescribeDomain, opensearch:AddTags
  - es:ListDomainNames, es:DescribeElasticsearchDomain, es:AddTags (for legacy domains)
  - cloudwatch:GetMetricStatistics, ec2:DescribeRegions

Examples:
  python aws-opensearch-idle-domain-auditor.py --regions us-east-1 us-west-2 --json
  python aws-opensearch-idle-domain-auditor.py --min-requests 25 --apply-tag --max-apply 10

Exit Codes:
  0 success
  1 unexpected error
"""
import argparse
import boto3
import datetime as dt
import json
import sys
from typing import Any, Dict, List, Optional, Tuple

CW_NS = "AWS/ES"


def parse_args():
    p = argparse.ArgumentParser(description="Audit idle OpenSearch/Elasticsearch domains (dry-run by default)")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all enabled)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--window-days", type=int, default=14, help="CloudWatch lookback window in days (default: 14)")
    p.add_argument("--period", type=int, default=3600, help="Metric period in seconds (default: 3600)")
    p.add_argument("--min-requests", type=int, default=10, help="Minimum HTTPRequests sum to consider active (default: 10)")
    p.add_argument("--max-cpu-avg", type=float, default=5.0, help="Maximum CPUUtilization average to still consider idle (default: 5.0)")
    p.add_argument("--max-jvm-avg", type=float, default=75.0, help="Maximum JVMMemoryPressure average to still consider idle (default: 75.0)")
    p.add_argument("--apply-tag", action="store_true", help="Apply a tag to flagged domains (dry-run by default)")
    p.add_argument("--tag-key", default="Cost:Review", help="Tag key (default: Cost:Review)")
    p.add_argument("--tag-value", default="opensearch-idle-candidate", help="Tag value (default: opensearch-idle-candidate)")
    p.add_argument("--max-apply", type=int, default=50, help="Max domains to tag (default: 50)")
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


def get_os_client(sess, region: str):
    # Prefer modern OpenSearch client; fall back to legacy ES if needed
    try:
        return sess.client("opensearch", region_name=region), "opensearch"
    except Exception:
        pass
    try:
        return sess.client("es", region_name=region), "es"
    except Exception:
        return None, None


def list_domains(client, flavor: str) -> List[str]:
    try:
        if flavor == "opensearch":
            resp = client.list_domain_names()
            names = [d.get("DomainName") for d in (resp.get("DomainNames") or []) if d.get("DomainName")]
            return names
        elif flavor == "es":
            resp = client.list_domain_names()
            names = [d.get("DomainName") if isinstance(d, dict) else d for d in (resp.get("DomainNames") or [])]
            return names
    except Exception:
        return []
    return []


def describe_domain(client, flavor: str, name: str) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
    try:
        if flavor == "opensearch":
            resp = client.describe_domain(DomainName=name)
            ds = resp.get("DomainStatus", {})
            return ds, ds.get("ARN")
        elif flavor == "es":
            resp = client.describe_elasticsearch_domain(DomainName=name)
            ds = resp.get("DomainStatus", {})
            return ds, ds.get("ARN")
    except Exception:
        return None, None
    return None, None


def cw_sum_metric(cw, domain_name: str, metric_name: str, start: dt.datetime, end: dt.datetime, period: int) -> float:
    try:
        resp = cw.get_metric_statistics(
            Namespace=CW_NS,
            MetricName=metric_name,
            Dimensions=[{"Name": "DomainName", "Value": domain_name}],
            StartTime=start,
            EndTime=end,
            Period=period,
            Statistics=["Sum"],
        )
        return float(sum(p.get("Sum", 0.0) for p in resp.get("Datapoints", [])))
    except Exception:
        return 0.0


def cw_avg_metric(cw, domain_name: str, metric_name: str, start: dt.datetime, end: dt.datetime, period: int) -> float:
    try:
        resp = cw.get_metric_statistics(
            Namespace=CW_NS,
            MetricName=metric_name,
            Dimensions=[{"Name": "DomainName", "Value": domain_name}],
            StartTime=start,
            EndTime=end,
            Period=period,
            Statistics=["Average"],
        )
        pts = resp.get("Datapoints", [])
        if not pts:
            return 0.0
        vals = [float(p.get("Average", 0.0)) for p in pts]
        return sum(vals) / len(vals)
    except Exception:
        return 0.0


def cw_min_metric(cw, domain_name: str, metric_name: str, start: dt.datetime, end: dt.datetime, period: int) -> float:
    try:
        resp = cw.get_metric_statistics(
            Namespace=CW_NS,
            MetricName=metric_name,
            Dimensions=[{"Name": "DomainName", "Value": domain_name}],
            StartTime=start,
            EndTime=end,
            Period=period,
            Statistics=["Minimum"],
        )
        pts = resp.get("Datapoints", [])
        if not pts:
            return 0.0
        vals = [float(p.get("Minimum", 0.0)) for p in pts]
        return min(vals) if vals else 0.0
    except Exception:
        return 0.0


def add_tags(client, flavor: str, arn: str, key: str, value: str) -> Optional[str]:
    try:
        if flavor == "opensearch":
            client.add_tags(ARN=arn, TagList=[{"Key": key, "Value": value}])
        elif flavor == "es":
            client.add_tags(ARN=arn, TagList=[{"Key": key, "Value": value}])
        else:
            return "no-client"
        return None
    except Exception as e:
        return str(e)


def main():
    args = parse_args()
    sess = session(args.profile)
    regions = discover_regions(sess, args.regions)

    end = dt.datetime.utcnow()
    start = end - dt.timedelta(days=args.window_days)

    results = []
    applied = 0

    for region in regions:
        os_client, flavor = get_os_client(sess, region)
        if not os_client:
            continue
        cw = sess.client("cloudwatch", region_name=region)

        names = list_domains(os_client, flavor)
        for name in names:
            status, arn = describe_domain(os_client, flavor, name)
            if not status:
                continue
            engine = "opensearch" if flavor == "opensearch" else "elasticsearch"

            req_sum = cw_sum_metric(cw, name, "HTTPRequests", start, end, args.period)
            cpu_avg = cw_avg_metric(cw, name, "CPUUtilization", start, end, args.period)
            jvm_avg = cw_avg_metric(cw, name, "JVMMemoryPressure", start, end, args.period)
            free_min_mib = cw_min_metric(cw, name, "FreeStorageSpace", start, end, args.period)
            free_min_gb = free_min_mib / 1024.0 if free_min_mib else 0.0

            is_idle = (req_sum <= args.min_requests) and (cpu_avg <= args.max_cpu_avg) and (jvm_avg <= args.max_jvm_avg)

            rec = {
                "region": region,
                "domain_name": name,
                "engine": engine,
                "requests_sum": req_sum,
                "cpu_avg": cpu_avg,
                "jvm_avg": jvm_avg,
                "free_storage_min_gb": free_min_gb,
                "flagged_idle": is_idle,
                "tag_attempted": False,
                "tag_error": None,
            }

            if is_idle and args.apply_tag and arn and applied < args.max_apply:
                err = add_tags(os_client, flavor, arn, args.tag_key, args.tag_value)
                rec["tag_attempted"] = True
                rec["tag_error"] = err
                if err is None:
                    applied += 1

            if is_idle:
                results.append(rec)

    payload = {
        "regions": regions,
        "window_days": args.window_days,
        "min_requests": args.min_requests,
        "max_cpu_avg": args.max_cpu_avg,
        "max_jvm_avg": args.max_jvm_avg,
        "apply_tag": args.apply_tag,
        "applied": applied,
        "results": results,
    }

    if args.json:
        print(json.dumps(payload, indent=2))
        return 0

    if not results:
        print("No idle OpenSearch/Elasticsearch domains found under current thresholds.")
        return 0

    header = ["Region", "Domain", "Engine", "ReqSum", "CPUAvg", "JVMAvg", "FreeGB(min)", "Tagged"]
    rows = [header]
    for r in results:
        rows.append([
            r["region"], r["domain_name"], r["engine"], int(r["requests_sum"]), f"{r['cpu_avg']:.2f}", f"{r['jvm_avg']:.2f}", f"{r['free_storage_min_gb']:.1f}",
            ("Y" if r["tag_attempted"] and not r["tag_error"] else ("ERR" if r["tag_error"] else "N")),
        ])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = '  '.join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print('  '.join('-' * w for w in widths))
        else:
            print(line)

    if not args.apply_tag:
        print("\nDry-run. Use --apply-tag to mark candidates for review.")
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
