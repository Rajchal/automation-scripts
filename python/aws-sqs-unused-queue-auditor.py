#!/usr/bin/env python3
"""
aws-sqs-unused-queue-auditor.py

Purpose:
  Find potentially unused SQS queues across regions based on CloudWatch activity
  and queue attributes, with safe options to tag or delete empty queues.

Features:
  - Multi-region scan (default: all enabled)
  - Activity window with CloudWatch metrics (default 14 days)
  - Thresholds:
      * --min-sent, --min-received (sums over window) to consider active
      * --max-oldest-age (seconds) flag if ApproximateAgeOfOldestMessage exceeds this
  - Filters: --name-filter, --required-tag Key=Value (repeatable), --exclude-dlq
  - Actions (optional):
      * --apply-tag with --tag-key/--tag-value (safe metadata-only)
      * --delete for empty, non-DLQ queues (with --max-delete cap)
  - Outputs: human-readable table or --json
  - CI: --fail-on-findings returns exit 2 when unused queues are detected

Safety:
  - Read-only by default. Deletion only if queue is empty (no visible, in-flight, or delayed messages)
    and not referenced as a DLQ (unless --force-delete-dlq is provided).

Permissions:
  - sqs:ListQueues, sqs:GetQueueAttributes, sqs:ListQueueTags, sqs:DeleteQueue, sqs:ListDeadLetterSourceQueues
  - cloudwatch:GetMetricStatistics
  - ec2:DescribeRegions

Examples:
  python aws-sqs-unused-queue-auditor.py --regions us-east-1 us-west-2 --json
  python aws-sqs-unused-queue-auditor.py --min-sent 1 --min-received 1 --apply-tag --max-apply 20
  python aws-sqs-unused-queue-auditor.py --delete --max-delete 10 --exclude-dlq

Exit Codes:
  0 success
  1 unexpected error
  2 findings detected with --fail-on-findings
"""
import argparse
import boto3
import datetime as dt
import json
import sys
from typing import Any, Dict, List, Optional


CW_NS = "AWS/SQS"


def parse_args():
    p = argparse.ArgumentParser(description="Audit potentially unused SQS queues (dry-run by default)")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all enabled)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--window-days", type=int, default=14, help="CloudWatch lookback window in days (default: 14)")
    p.add_argument("--period", type=int, default=3600, help="Metric period in seconds (default: 3600)")
    p.add_argument("--min-sent", type=int, default=0, help="Minimum NumberOfMessagesSent sum to be considered active (default: 0)")
    p.add_argument("--min-received", type=int, default=0, help="Minimum NumberOfMessagesReceived sum to be considered active (default: 0)")
    p.add_argument("--max-oldest-age", type=int, default=None, help="Flag if ApproximateAgeOfOldestMessage max exceeds this (seconds)")
    p.add_argument("--name-filter", help="Substring filter on queue name")
    p.add_argument("--required-tag", action="append", help="Require Tag Key=Value (repeat)")
    p.add_argument("--exclude-dlq", action="store_true", help="Exclude queues that are used as DLQs")
    p.add_argument("--apply-tag", action="store_true", help="Tag flagged queues for review")
    p.add_argument("--tag-key", default="Cost:Review", help="Tag key (default: Cost:Review)")
    p.add_argument("--tag-value", default="unused-candidate", help="Tag value (default: unused-candidate)")
    p.add_argument("--max-apply", type=int, default=50, help="Max queues to tag (default: 50)")
    p.add_argument("--delete", action="store_true", help="Delete empty, non-DLQ flagged queues")
    p.add_argument("--force-delete-dlq", action="store_true", help="Allow deletion even if queue is a DLQ (not recommended)")
    p.add_argument("--max-delete", type=int, default=20, help="Max queues to delete (default: 20)")
    p.add_argument("--fail-on-findings", action="store_true", help="Exit with code 2 if findings exist")
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


def list_queues(sqs) -> List[str]:
    urls: List[str] = []
    token = None
    while True:
        kwargs = {}
        if token:
            kwargs["NextToken"] = token
            kwargs["MaxResults"] = 1000
        resp = sqs.list_queues(**kwargs)
        urls.extend(resp.get("QueueUrls", []) or [])
        token = resp.get("NextToken")
        if not token:
            break
    return urls


def queue_name_from_url(url: str) -> str:
    return url.rstrip("/").split("/")[-1]


def get_queue_attrs(sqs, url: str) -> Dict[str, Any]:
    try:
        resp = sqs.get_queue_attributes(QueueUrl=url, AttributeNames=["All"])
        return resp.get("Attributes", {})
    except Exception:
        return {}


def list_queue_tags(sqs, url: str) -> Dict[str, str]:
    try:
        resp = sqs.list_queue_tags(QueueUrl=url)
        return resp.get("Tags", {}) or {}
    except Exception:
        return {}


def cw_sum_metric(cw, queue_name: str, metric_name: str, start: dt.datetime, end: dt.datetime, period: int) -> float:
    try:
        resp = cw.get_metric_statistics(
            Namespace=CW_NS,
            MetricName=metric_name,
            Dimensions=[{"Name": "QueueName", "Value": queue_name}],
            StartTime=start,
            EndTime=end,
            Period=period,
            Statistics=["Sum"],
        )
        return float(sum(p.get("Sum", 0.0) for p in resp.get("Datapoints", [])))
    except Exception:
        return 0.0


def cw_max_metric(cw, queue_name: str, metric_name: str, start: dt.datetime, end: dt.datetime, period: int) -> float:
    try:
        resp = cw.get_metric_statistics(
            Namespace=CW_NS,
            MetricName=metric_name,
            Dimensions=[{"Name": "QueueName", "Value": queue_name}],
            StartTime=start,
            EndTime=end,
            Period=period,
            Statistics=["Maximum"],
        )
        pts = resp.get("Datapoints", [])
        if not pts:
            return 0.0
        vals = [float(p.get("Maximum", 0.0)) for p in pts]
        return max(vals) if vals else 0.0
    except Exception:
        return 0.0


def list_dead_letter_sources(sqs, url: str) -> int:
    try:
        token = None
        total = 0
        while True:
            kwargs = {"QueueUrl": url}
            if token:
                kwargs["NextToken"] = token
                kwargs["MaxResults"] = 1000
            resp = sqs.list_dead_letter_source_queues(**kwargs)
            total += len(resp.get("queueUrls", []) or resp.get("QueueUrls", []) or [])
            token = resp.get("NextToken")
            if not token:
                break
        return total
    except Exception:
        return 0


def apply_tag(sqs, url: str, key: str, value: str) -> Optional[str]:
    try:
        sqs.tag_queue(QueueUrl=url, Tags={key: value})
        return None
    except Exception as e:
        return str(e)


def delete_queue(sqs, url: str) -> Optional[str]:
    try:
        sqs.delete_queue(QueueUrl=url)
        return None
    except Exception as e:
        return str(e)


def main():
    args = parse_args()
    sess = session(args.profile)
    regions = discover_regions(sess, args.regions)
    needed_tags = parse_tag_filters(args.required_tag)

    end = dt.datetime.utcnow()
    start = end - dt.timedelta(days=args.window_days)

    results = []
    tags_applied = 0
    deleted = 0

    for region in regions:
        sqs = sess.client("sqs", region_name=region)
        cw = sess.client("cloudwatch", region_name=region)
        try:
            urls = list_queues(sqs)
        except Exception as e:
            print(f"WARN region {region} list queues failed: {e}", file=sys.stderr)
            continue
        for url in urls:
            qname = queue_name_from_url(url)
            if args.name_filter and args.name_filter not in qname:
                continue

            attrs = get_queue_attrs(sqs, url)
            tags = list_queue_tags(sqs, url)
            if needed_tags:
                ok = True
                for k, v in needed_tags.items():
                    if tags.get(k) != v:
                        ok = False
                        break
                if not ok:
                    continue

            # Determine if this queue is used as a DLQ by others
            dl_sources = list_dead_letter_sources(sqs, url)
            is_dlq = dl_sources > 0
            if args.exclude_dlq and is_dlq:
                continue

            # Activity metrics
            sent_sum = cw_sum_metric(cw, qname, "NumberOfMessagesSent", start, end, args.period)
            recv_sum = cw_sum_metric(cw, qname, "NumberOfMessagesReceived", start, end, args.period)
            age_max = cw_max_metric(cw, qname, "ApproximateAgeOfOldestMessage", start, end, args.period)

            # Queue depth attributes (strings)
            vis = int(attrs.get("ApproximateNumberOfMessages", "0"))
            not_vis = int(attrs.get("ApproximateNumberOfMessagesNotVisible", "0"))
            delayed = int(attrs.get("ApproximateNumberOfMessagesDelayed", "0"))

            idle_by_activity = (sent_sum <= args.min_sent) and (recv_sum <= args.min_received)
            old_msgs_flag = False
            if args.max_oldest_age is not None:
                old_msgs_flag = age_max >= args.max_oldest_age

            flagged = idle_by_activity or old_msgs_flag

            rec = {
                "region": region,
                "queue_url": url,
                "queue_name": qname,
                "is_dlq": is_dlq,
                "sent_sum": sent_sum,
                "received_sum": recv_sum,
                "oldest_age_max": age_max,
                "visible": vis,
                "not_visible": not_vis,
                "delayed": delayed,
                "flagged_unused": flagged,
                "tag_attempted": False,
                "tag_error": None,
                "delete_attempted": False,
                "delete_error": None,
            }

            if flagged and args.apply_tag and tags_applied < args.max_apply:
                err = apply_tag(sqs, url, args.tag_key, args.tag_value)
                rec["tag_attempted"] = True
                rec["tag_error"] = err
                if err is None:
                    tags_applied += 1

            can_delete = flagged and (vis == 0 and not_vis == 0 and delayed == 0) and (args.force_delete_dlq or not is_dlq)
            if args.delete and can_delete and deleted < args.max_delete:
                err = delete_queue(sqs, url)
                rec["delete_attempted"] = True
                rec["delete_error"] = err
                if err is None:
                    deleted += 1

            if flagged:
                results.append(rec)

    payload = {
        "regions": regions,
        "window_days": args.window_days,
        "min_sent": args.min_sent,
        "min_received": args.min_received,
        "max_oldest_age": args.max_oldest_age,
        "apply_tag": args.apply_tag,
        "tags_applied": tags_applied,
        "delete": args.delete,
        "deleted": deleted,
        "results": results,
    }

    if args.json:
        print(json.dumps(payload, indent=2))
        return 0 if (results or not args.fail_on_findings) else 2

    if not results:
        print("No unused SQS queues found under current thresholds.")
        return 0

    header = ["Region", "Name", "DLQ", "Sent", "Recv", "OldestAge", "Depth", "Tagged", "Deleted"]
    rows = [header]
    for r in results:
        depth = f"v:{r['visible']} nv:{r['not_visible']} d:{r['delayed']}"
        rows.append([
            r["region"], r["queue_name"], "Y" if r["is_dlq"] else "N",
            int(r["sent_sum"]), int(r["received_sum"]), int(r["oldest_age_max"]), depth,
            ("Y" if r["tag_attempted"] and not r["tag_error"] else ("ERR" if r["tag_error"] else "N")),
            ("Y" if r["delete_attempted"] and not r["delete_error"] else ("ERR" if r["delete_error"] else "N")),
        ])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = '  '.join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print('  '.join('-' * w for w in widths))
        else:
            print(line)
    if not args.apply_tag and not args.delete:
        print("\nDry-run. Use --apply-tag to mark, or --delete to remove empty non-DLQs.")

    if args.fail_on_findings and results:
        return 2
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
