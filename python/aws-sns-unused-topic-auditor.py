#!/usr/bin/env python3
"""
aws-sns-unused-topic-auditor.py

Purpose:
  Identify potentially unused SNS topics across regions using CloudWatch metrics and
  subscription state, with optional safe tagging or deletion (only when unsubscribed).

Features:
  - Multi-region scan (default: all enabled)
  - CloudWatch window/period options (default 14 days / 1h)
  - Thresholds:
      * --min-published (Sum of NumberOfMessagesPublished)
      * --min-delivered (Sum of NumberOfNotificationsDelivered)
  - Filters: --name-filter, --required-tag Key=Value (repeatable)
  - Actions (optional):
      * --apply-tag with --tag-key/--tag-value (metadata only)
      * --delete topics with zero active subscriptions (cap with --max-delete)
  - Outputs: human-readable table or --json
  - CI: --fail-on-findings returns exit 2 if unused topics are detected

Safety:
  - Read-only by default. Deletion only when there are zero subscriptions on the topic.

Permissions:
  - sns:ListTopics, sns:GetTopicAttributes, sns:ListSubscriptionsByTopic, sns:ListTagsForResource, sns:TagResource, sns:DeleteTopic
  - cloudwatch:GetMetricStatistics
  - ec2:DescribeRegions (for region discovery)

Examples:
  python aws-sns-unused-topic-auditor.py --regions us-east-1 us-west-2 --json
  python aws-sns-unused-topic-auditor.py --min-published 1 --min-delivered 1 --apply-tag --max-apply 20
  python aws-sns-unused-topic-auditor.py --delete --max-delete 10

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


CW_NS = "AWS/SNS"


def parse_args():
    p = argparse.ArgumentParser(description="Audit potentially unused SNS topics (dry-run by default)")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all enabled)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--window-days", type=int, default=14, help="CloudWatch lookback window in days (default: 14)")
    p.add_argument("--period", type=int, default=3600, help="Metric period in seconds (default: 3600)")
    p.add_argument("--min-published", type=int, default=0, help="Minimum NumberOfMessagesPublished sum to be considered active (default: 0)")
    p.add_argument("--min-delivered", type=int, default=0, help="Minimum NumberOfNotificationsDelivered sum to be considered active (default: 0)")
    p.add_argument("--name-filter", help="Substring filter on topic ARN or display name")
    p.add_argument("--required-tag", action="append", help="Require Tag Key=Value (repeat)")
    p.add_argument("--apply-tag", action="store_true", help="Tag flagged topics for review")
    p.add_argument("--tag-key", default="Cost:Review", help="Tag key (default: Cost:Review)")
    p.add_argument("--tag-value", default="unused-candidate", help="Tag value (default: unused-candidate)")
    p.add_argument("--max-apply", type=int, default=50, help="Max topics to tag (default: 50)")
    p.add_argument("--delete", action="store_true", help="Delete flagged topics with zero subscriptions")
    p.add_argument("--max-delete", type=int, default=20, help="Max topics to delete (default: 20)")
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


def list_topics(sns) -> List[str]:
    arns: List[str] = []
    token = None
    while True:
        kwargs = {}
        if token:
            kwargs["NextToken"] = token
        resp = sns.list_topics(**kwargs)
        arns.extend([t.get("TopicArn") for t in resp.get("Topics", []) if t.get("TopicArn")])
        token = resp.get("NextToken")
        if not token:
            break
    return arns


def topic_name_from_arn(arn: str) -> str:
    # arn:aws:sns:region:account:topic-name
    return arn.split(":")[-1]


def get_topic_attrs(sns, arn: str) -> Dict[str, Any]:
    try:
        resp = sns.get_topic_attributes(TopicArn=arn)
        return resp.get("Attributes", {})
    except Exception:
        return {}


def list_subscriptions_by_topic(sns, arn: str) -> List[Dict[str, Any]]:
    subs: List[Dict[str, Any]] = []
    token = None
    while True:
        kwargs = {"TopicArn": arn}
        if token:
            kwargs["NextToken"] = token
        resp = sns.list_subscriptions_by_topic(**kwargs)
        subs.extend(resp.get("Subscriptions", []) or [])
        token = resp.get("NextToken")
        if not token:
            break
    return subs


def list_tags(sns, arn: str) -> Dict[str, str]:
    try:
        resp = sns.list_tags_for_resource(ResourceArn=arn)
        return {t.get("Key"): t.get("Value") for t in resp.get("Tags", [])}
    except Exception:
        return {}


def cw_sum_metric(cw, topic_name: str, metric_name: str, start: dt.datetime, end: dt.datetime, period: int) -> float:
    try:
        resp = cw.get_metric_statistics(
            Namespace=CW_NS,
            MetricName=metric_name,
            Dimensions=[{"Name": "TopicName", "Value": topic_name}],
            StartTime=start,
            EndTime=end,
            Period=period,
            Statistics=["Sum"],
        )
        return float(sum(p.get("Sum", 0.0) for p in resp.get("Datapoints", [])))
    except Exception:
        return 0.0


def apply_tag(sns, arn: str, key: str, value: str) -> Optional[str]:
    try:
        sns.tag_resource(ResourceArn=arn, Tags=[{"Key": key, "Value": value}])
        return None
    except Exception as e:
        return str(e)


def delete_topic(sns, arn: str) -> Optional[str]:
    try:
        sns.delete_topic(TopicArn=arn)
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
        sns = sess.client("sns", region_name=region)
        cw = sess.client("cloudwatch", region_name=region)
        try:
            arns = list_topics(sns)
        except Exception as e:
            print(f"WARN region {region} list topics failed: {e}", file=sys.stderr)
            continue
        for arn in arns:
            tname = topic_name_from_arn(arn)
            attrs = get_topic_attrs(sns, arn)
            if args.name_filter:
                name_hit = args.name_filter in arn or args.name_filter in attrs.get("DisplayName", "")
                if not name_hit:
                    continue

            tags = list_tags(sns, arn)
            if needed_tags:
                ok = True
                for k, v in needed_tags.items():
                    if tags.get(k) != v:
                        ok = False
                        break
                if not ok:
                    continue

            subs = list_subscriptions_by_topic(sns, arn)
            active_subs = [s for s in subs if (s.get("SubscriptionArn") and s.get("SubscriptionArn") != "PendingConfirmation")]

            pub_sum = cw_sum_metric(cw, tname, "NumberOfMessagesPublished", start, end, args.period)
            deliv_sum = cw_sum_metric(cw, tname, "NumberOfNotificationsDelivered", start, end, args.period)

            idle_by_activity = (pub_sum <= args.min_published) and (deliv_sum <= args.min_delivered)

            flagged = idle_by_activity

            rec = {
                "region": region,
                "topic_arn": arn,
                "topic_name": tname,
                "display_name": attrs.get("DisplayName"),
                "subscriptions": len(subs),
                "active_subscriptions": len(active_subs),
                "published_sum": pub_sum,
                "delivered_sum": deliv_sum,
                "flagged_unused": flagged,
                "tag_attempted": False,
                "tag_error": None,
                "delete_attempted": False,
                "delete_error": None,
            }

            if flagged and args.apply_tag and tags_applied < args.max_apply:
                err = apply_tag(sns, arn, args.tag_key, args.tag_value)
                rec["tag_attempted"] = True
                rec["tag_error"] = err
                if err is None:
                    tags_applied += 1

            can_delete = flagged and (len(active_subs) == 0)
            if args.delete and can_delete and deleted < args.max_delete:
                err = delete_topic(sns, arn)
                rec["delete_attempted"] = True
                rec["delete_error"] = err
                if err is None:
                    deleted += 1

            if flagged:
                results.append(rec)

    payload = {
        "regions": regions,
        "window_days": args.window_days,
        "min_published": args.min_published,
        "min_delivered": args.min_delivered,
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
        print("No unused SNS topics found under current thresholds.")
        return 0

    header = ["Region", "Topic", "Subs", "ActiveSubs", "Published", "Delivered", "Tagged", "Deleted"]
    rows = [header]
    for r in results:
        rows.append([
            r["region"], r["topic_name"], r["subscriptions"], r["active_subscriptions"],
            int(r["published_sum"]), int(r["delivered_sum"]),
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
        print("\nDry-run. Use --apply-tag to mark, or --delete to remove unused topics with zero subscriptions.")

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
