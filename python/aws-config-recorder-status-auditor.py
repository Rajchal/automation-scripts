#!/usr/bin/env python3
"""
aws-config-recorder-status-auditor.py

Purpose:
  Ensure AWS Config is properly enabled across regions by checking the presence of
  configuration recorders, their recording status, and delivery channels. Optionally
  start recording when a recorder exists but is stopped.

Features:
  - Multi-region scan (default: all enabled regions)
  - Reports per-region:
      * Missing configuration recorder
      * Missing delivery channel
      * Recording disabled or errors in last status
      * Delivery channel target (S3 bucket, SNS topic)
  - Optional remediation: --apply-start to start existing, stopped recorders
  - Safety cap with --max-apply
  - JSON or human-readable output
  - CI-friendly: --fail-on-findings returns exit code 2 when issues are found

Permissions:
  - config:DescribeConfigurationRecorders, config:DescribeConfigurationRecorderStatus,
    config:DescribeDeliveryChannels, config:StartConfigurationRecorder
  - ec2:DescribeRegions (for region discovery)

Examples:
  python aws-config-recorder-status-auditor.py --json
  python aws-config-recorder-status-auditor.py --apply-start --max-apply 10

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


def parse_args():
    p = argparse.ArgumentParser(description="Audit AWS Config recorder status across regions")
    p.add_argument("--regions", nargs="*", help="Regions to scan (default: all enabled)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--apply-start", action="store_true", help="Start existing, stopped recorders")
    p.add_argument("--max-apply", type=int, default=50, help="Max recorders to start (default: 50)")
    p.add_argument("--fail-on-findings", action="store_true", help="Exit 2 if any misconfigurations are found")
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


def list_recorders(cfg):
    try:
        resp = cfg.describe_configuration_recorders()
        return resp.get("ConfigurationRecorders", [])
    except Exception:
        return []


def list_recorders_status(cfg):
    try:
        resp = cfg.describe_configuration_recorder_status()
        return resp.get("ConfigurationRecordersStatus", [])
    except Exception:
        return []


def list_delivery_channels(cfg):
    try:
        resp = cfg.describe_delivery_channels()
        return resp.get("DeliveryChannels", [])
    except Exception:
        return []


def start_recorder(cfg, name: str) -> Optional[str]:
    try:
        cfg.start_configuration_recorder(ConfigurationRecorderName=name)
        return None
    except Exception as e:
        return str(e)


def main():
    args = parse_args()
    sess = session(args.profile)
    regions = discover_regions(sess, args.regions)

    results = []
    started = 0

    for region in regions:
        cfg = sess.client("config", region_name=region)
        recs = list_recorders(cfg)
        recs_status = list_recorders_status(cfg)
        chans = list_delivery_channels(cfg)

        has_recorder = len(recs) > 0
        has_channel = len(chans) > 0

        # Map status by name for clarity
        status_by_name: Dict[str, Dict[str, Any]] = {s.get("name"): s for s in recs_status}

        # Determine recording status summary
        any_recording = any(bool(s.get("recording")) for s in recs_status)
        errors = [s.get("lastErrorCode") or s.get("lastStartStatus") for s in recs_status if (s.get("lastErrorCode") or s.get("lastStartStatus") == "Failed")]

        # Delivery channel targets (only report the first for brevity)
        dc = chans[0] if chans else {}
        s3_bucket = (dc.get("s3BucketName") or None) if dc else None
        sns_topic = (dc.get("snsTopicARN") or None) if dc else None

        # Recorder names and those stopped
        rec_names = [r.get("name") for r in recs]
        stopped_names = [n for n in rec_names if not (status_by_name.get(n) or {}).get("recording")]

        rec = {
            "region": region,
            "has_recorder": has_recorder,
            "has_delivery_channel": has_channel,
            "recorder_names": rec_names,
            "any_recording": any_recording,
            "stopped_recorders": stopped_names,
            "s3_bucket": s3_bucket,
            "sns_topic": sns_topic,
            "apply_attempted": False,
            "apply_error": None,
        }

        # Findings: missing components or not recording
        finding = (not has_recorder) or (not has_channel) or (not any_recording)

        # Attempt remediation if requested
        if args.apply_start and finding and has_recorder and stopped_names and started < args.max_apply:
            # Start the first stopped recorder (start for others can be run in subsequent runs)
            to_start = stopped_names[0]
            err = start_recorder(cfg, to_start)
            rec["apply_attempted"] = True
            rec["apply_error"] = err
            if err is None:
                started += 1

        if finding:
            results.append(rec)

    payload = {
        "regions": regions,
        "apply_start": args.apply_start,
        "started": started,
        "results": results,
    }

    if args.json:
        print(json.dumps(payload, indent=2))
        return 0 if (results or not args.fail_on_findings) else 2

    if not results:
        print("AWS Config appears healthy across scanned regions (recorder + delivery channel + recording).")
        return 0

    header = ["Region", "HasRec", "HasChan", "AnyRec", "Stopped", "S3Bucket", "Applied"]
    rows = [header]
    for r in results:
        rows.append([
            r["region"], "Y" if r["has_recorder"] else "N", "Y" if r["has_delivery_channel"] else "N",
            "Y" if r["any_recording"] else "N", ",".join(r["stopped_recorders"]) or "-",
            r.get("s3_bucket") or "-",
            ("Y" if r["apply_attempted"] and not r["apply_error"] else ("ERR" if r["apply_error"] else "N")),
        ])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = '  '.join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print('  '.join('-' * w for w in widths))
        else:
            print(line)
    if not args.apply_start:
        print("\nDry-run. Use --apply-start to start existing, stopped recorders.")

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
