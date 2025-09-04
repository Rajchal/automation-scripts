#!/usr/bin/env python3
"""
AWS EBS Low IOPS / Throughput Heuristic Detector

Purpose:
  Identify gp2/gp3 (and optionally io1/io2) volumes that appear under-provisioned or
  consistently reaching performance ceilings, using recent CloudWatch metrics.

Limitations:
  - Requires AWS credentials with permissions: ec2:DescribeVolumes, cloudwatch:GetMetricStatistics
  - This is a heuristic; it does not guarantee saturation. Always validate with
    detailed workload profiling.

Logic Overview:
  For each volume (default types: gp2, gp3):
    * Fetch Avg + Max of VolumeReadOps + VolumeWriteOps over --period seconds windows for --lookback-minutes
    * Compute combined IOPS = (ReadOps + WriteOps)/period
    * For gp2: burst baseline = max(100, 3 * SizeGiB) (capped by gp2 design at 16000)
      If MaxIOPS >= 0.9 * baseline for >= --breach-windows windows -> flag
    * For gp3: use provisioned IOPS (Iops) field. If absent fallback to 3000 default baseline.
      If MaxIOPS >= 0.9 * provisioned for >= --breach-windows windows -> flag
    * For gp2, also flag if baseline < --min-baseline-iops (suggest gp3 migration)

Output Columns (text mode):
  VolumeId Type SizeGiB MaxIOPS AvgIOPS Baseline/Prov BreachWindows Reason

Examples:
  python aws-ebs-low-iops-detector.py
  python aws-ebs-low-iops-detector.py --profile prod --region us-east-1 --include io1,io2
  python aws-ebs-low-iops-detector.py --min-baseline-iops 1500 --lookback-minutes 180

Exit codes:
  0 success
  1 AWS/API error
"""
from __future__ import annotations
import argparse
import datetime as dt
import math
import sys
from typing import Dict, List, Tuple
import boto3
from botocore.exceptions import BotoCoreError, ClientError

DEFAULT_VOLUME_TYPES = ["gp2", "gp3"]
SUPPORTED_TYPES = ["gp2", "gp3", "io1", "io2"]


def parse_args():
    p = argparse.ArgumentParser(description="Detect potentially under-provisioned or saturated EBS volumes")
    p.add_argument("--region", help="AWS region (overrides configured)")
    p.add_argument("--profile", help="AWS CLI profile to use")
    p.add_argument("--include", help="Comma list of volume types to include (default gp2,gp3)")
    p.add_argument("--period", type=int, default=300, help="Metric period seconds (default 300)")
    p.add_argument("--lookback-minutes", type=int, default=120, help="How far back to look for metrics (default 120)")
    p.add_argument("--breach-windows", type=int, default=3, help="Number of windows exceeding 90% baseline to flag (default 3)")
    p.add_argument("--min-baseline-iops", type=int, default=1000, help="Flag gp2 volumes whose baseline < this (default 1000)")
    p.add_argument("--json", action="store_true", help="JSON output")
    return p.parse_args()


def client_for(service: str, profile: str = None, region: str = None):
    session_args = {}
    if profile:
        session_args['profile_name'] = profile
    session = boto3.Session(**session_args) if session_args else boto3.Session()
    return session.client(service, region_name=region) if region else session.client(service)


def gp2_baseline(size_gib: int) -> int:
    # gp2 baseline = 3 * size GiB, min 100, max 16000
    return max(100, min(16000, 3 * size_gib))


def fetch_iops_metrics(cw, volume_id: str, start: dt.datetime, end: dt.datetime, period: int):
    # CloudWatch Namespace: AWS/EBS Metrics: VolumeReadOps, VolumeWriteOps
    dims = [{'Name': 'VolumeId', 'Value': volume_id}]
    metrics = {}
    for metric_name in ['VolumeReadOps', 'VolumeWriteOps']:
        resp = cw.get_metric_statistics(
            Namespace='AWS/EBS',
            MetricName=metric_name,
            Dimensions=dims,
            StartTime=start,
            EndTime=end,
            Period=period,
            Statistics=['Sum'],
        )
        metrics[metric_name] = resp.get('Datapoints', [])
    # Align timestamps: map timestamp -> (read_sum, write_sum)
    points: Dict[dt.datetime, Dict[str, float]] = {}
    for dp in metrics['VolumeReadOps']:
        points.setdefault(dp['Timestamp'], {})['r'] = dp['Sum']
    for dp in metrics['VolumeWriteOps']:
        points.setdefault(dp['Timestamp'], {})['w'] = dp['Sum']
    series = []
    for ts, vals in sorted(points.items()):
        read_sum = vals.get('r', 0.0)
        write_sum = vals.get('w', 0.0)
        total_iops = (read_sum + write_sum) / period
        series.append({'timestamp': ts, 'iops': total_iops})
    return series


def analyze_volume(vol, metrics_series, vol_type: str, breach_windows: int, min_baseline_iops: int):
    size = vol.get('Size')
    result = {
        'VolumeId': vol['VolumeId'],
        'Type': vol_type,
        'SizeGiB': size,
        'MaxIOPS': None,
        'AvgIOPS': None,
        'BaselineOrProvisioned': None,
        'BreachWindows': 0,
        'Reasons': [],
    }
    if not metrics_series:
        result['Reasons'].append('no-metrics')
        return result
    iops_values = [p['iops'] for p in metrics_series]
    max_iops = max(iops_values)
    avg_iops = sum(iops_values) / len(iops_values)
    result['MaxIOPS'] = round(max_iops, 2)
    result['AvgIOPS'] = round(avg_iops, 2)

    if vol_type == 'gp2':
        baseline = gp2_baseline(size)
        result['BaselineOrProvisioned'] = baseline
        threshold = 0.9 * baseline
        breach_count = sum(1 for v in iops_values if v >= threshold)
        result['BreachWindows'] = breach_count
        if breach_count >= breach_windows:
            result['Reasons'].append('near-baseline-saturation')
        if baseline < min_baseline_iops:
            result['Reasons'].append('low-gp2-baseline-consider-gp3')
    elif vol_type == 'gp3':
        # gp3 volumes have Provisioned IOPS in Iops field, else default baseline 3000
        provisioned = vol.get('Iops') or 3000
        result['BaselineOrProvisioned'] = provisioned
        threshold = 0.9 * provisioned
        breach_count = sum(1 for v in iops_values if v >= threshold)
        result['BreachWindows'] = breach_count
        if breach_count >= breach_windows:
            result['Reasons'].append('near-provisioned-saturation')
    else:
        # io1/io2 - use Provisioned IOPS
        provisioned = vol.get('Iops') or 0
        result['BaselineOrProvisioned'] = provisioned
        if provisioned:
            threshold = 0.9 * provisioned
            breach_count = sum(1 for v in iops_values if v >= threshold)
            result['BreachWindows'] = breach_count
            if breach_count >= breach_windows:
                result['Reasons'].append('near-provisioned-saturation')
        else:
            result['Reasons'].append('no-provisioned-iops-info')

    return result


def main():
    args = parse_args()
    include_types = [t.strip() for t in (args.include.split(',') if args.include else DEFAULT_VOLUME_TYPES) if t.strip()]
    include_types = [t for t in include_types if t in SUPPORTED_TYPES]

    try:
        ec2 = client_for('ec2', args.profile, args.region)
        cw = client_for('cloudwatch', args.profile, args.region)

        vols_resp = ec2.describe_volumes(Filters=[{'Name': 'volume-type', 'Values': include_types}])
        volumes = vols_resp.get('Volumes', [])
        if not volumes:
            print('No volumes found for specified types.')
            return

        end = dt.datetime.utcnow()
        start = end - dt.timedelta(minutes=args.lookback_minutes)

        results = []
        for vol in volumes:
            series = fetch_iops_metrics(cw, vol['VolumeId'], start, end, args.period)
            analyzed = analyze_volume(vol, series, vol['VolumeType'], args.breach_windows, args.min_baseline_iops)
            results.append(analyzed)

        # Filter to those with Reasons unless json wants full dataset
        flagged = [r for r in results if r['Reasons']]

        if args.json:
            import json
            print(json.dumps({'volumes': results, 'flagged': flagged}, default=str, indent=2))
            return

        print(f"Analyzed {len(results)} volumes (types: {','.join(include_types)}) lookback={args.lookback_minutes}m period={args.period}s")
        if not flagged:
            print('No concerning volumes detected.')
            return
        header = f"{'VolumeId':<20} {'Type':<5} {'Size':>5} {'MaxIOPS':>10} {'AvgIOPS':>10} {'Baseline/Prov':>13} {'BreachWin':>9} Reasons"
        print(header)
        print('-' * len(header))
        for r in flagged:
            print(f"{r['VolumeId']:<20} {r['Type']:<5} {r['SizeGiB']:>5} {r['MaxIOPS']:>10} {r['AvgIOPS']:>10} {r['BaselineOrProvisioned']:>13} {r['BreachWindows']:>9} {','.join(r['Reasons'])}")

        print("\nSuggestions:")
        for r in flagged:
            if 'low-gp2-baseline-consider-gp3' in r['Reasons']:
                print(f"  {r['VolumeId']}: Consider migrating gp2->{ 'gp3 (baseline 3000 IOPS + configurable)' }")
            if 'near-baseline-saturation' in r['Reasons'] and r['Type'] == 'gp2':
                print(f"  {r['VolumeId']}: Consistent near baseline; evaluate gp3 migration or workload tuning")
            if 'near-provisioned-saturation' in r['Reasons'] and r['Type'] == 'gp3':
                print(f"  {r['VolumeId']}: Approaching provisioned IOPS; consider increasing provisioned IOPS")

    except (BotoCoreError, ClientError) as e:
        print(f"AWS Error: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()
