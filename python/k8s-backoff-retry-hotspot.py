#!/usr/bin/env python3
"""
Kubernetes Backoff / Retry Hotspot Detector

Identifies Jobs and CronJobs exhibiting high failure or retry churn so you can
prioritize remediation and resource efficiency.

Heuristics (per Job):
  - fail_ratio = failed / max(1, (succeeded + failed)) >= --fail-ratio (default 0.6)
  - near_backoff: failed attempts >= (backoffLimit * --backoff-percent) (default 0.8)
  - long_pending: active > 0 and startTime older than --pending-minutes

Heuristics (per CronJob aggregate):
  - consecutive_failed >= --cron-consecutive-failures
  - average job fail_ratio across recent N jobs (--cron-window) >= --fail-ratio

Output: human or JSON. Exit 0 always (non-policy tool).

Usage:
  python k8s-backoff-retry-hotspot.py
  python k8s-backoff-retry-hotspot.py -n batch --json
  python k8s-backoff-retry-hotspot.py --fail-ratio 0.5 --cron-consecutive-failures 3

Notes:
  - Requires list permission on jobs/cronjobs.
  - Only looks at Jobs created within last --max-age-hours (default 24) to bound data.
  - Does not dereference Pods directly (fast); can extend to inspect Pod statuses if needed.
"""
from __future__ import annotations
import argparse
import datetime as dt
import json
from typing import Dict, List, Any, Optional
from kubernetes import client, config
from kubernetes.client import ApiException

Finding = Dict[str, Any]


def load_cfg():
    try:
        config.load_kube_config()
    except Exception:
        config.load_incluster_config()


def parse_args():
    p = argparse.ArgumentParser(description='Detect Job / CronJob retry hotspots')
    p.add_argument('-n', '--namespace', help='Namespace scope (default all)')
    p.add_argument('--fail-ratio', type=float, default=0.6, help='Failure ratio threshold (default 0.6)')
    p.add_argument('--backoff-percent', type=float, default=0.8, help='Percent of backoffLimit to treat as near backoff (default 0.8)')
    p.add_argument('--pending-minutes', type=int, default=30, help='Active job pending minutes threshold (default 30)')
    p.add_argument('--cron-window', type=int, default=5, help='Recent N jobs per CronJob to evaluate (default 5)')
    p.add_argument('--cron-consecutive-failures', type=int, default=2, help='Consecutive failures threshold for CronJobs (default 2)')
    p.add_argument('--max-age-hours', type=int, default=24, help='Ignore jobs older than this many hours (default 24)')
    p.add_argument('--json', action='store_true', help='JSON output')
    return p.parse_args()


def parse_time(ts: Optional[str]) -> Optional[dt.datetime]:
    if not ts:
        return None
    try:
        # API returns RFC3339; use fromisoformat after replacing Z
        if ts.endswith('Z'):
            ts = ts[:-1] + '+00:00'
        return dt.datetime.fromisoformat(ts)
    except Exception:
        return None


def job_age_hours(job) -> float:
    st = getattr(job.status, 'start_time', None)
    if not st:
        return 0.0
    st_dt = st if isinstance(st, dt.datetime) else parse_time(str(st))
    if not st_dt:
        return 0.0
    now = dt.datetime.now(dt.timezone.utc)
    if not st_dt.tzinfo:
        st_dt = st_dt.replace(tzinfo=dt.timezone.utc)
    return (now - st_dt).total_seconds() / 3600.0


def collect_jobs(batch: client.BatchV1Api, namespace: Optional[str], max_age_hours: int):
    if namespace:
        jobs = batch.list_namespaced_job(namespace).items
    else:
        jobs = batch.list_job_for_all_namespaces().items
    recent = []
    for j in jobs:
        if job_age_hours(j) <= max_age_hours:
            recent.append(j)
    return recent


def collect_cronjobs(batch: client.BatchV1Api, namespace: Optional[str]):
    if namespace:
        cjs = batch.list_namespaced_cron_job(namespace).items
    else:
        cjs = batch.list_cron_job_for_all_namespaces().items
    return cjs


def eval_jobs(jobs, args) -> List[Finding]:
    findings: List[Finding] = []
    for j in jobs:
        ns = j.metadata.namespace
        name = j.metadata.name
        s = j.status
        failed = s.failed or 0
        succeeded = s.succeeded or 0
        active = s.active or 0
        total = failed + succeeded
        fail_ratio = failed / total if total > 0 else 0.0
        backoff_limit = j.spec.backoff_limit or 6
        near_backoff = failed >= backoff_limit * args.backoff_percent and failed > 0
        reasons = []
        if total > 0 and fail_ratio >= args.fail_ratio:
            reasons.append('high-fail-ratio')
        if near_backoff:
            reasons.append('near-backoff-limit')
        # Pending
        if active > 0 and job_age_hours(j) * 60 >= args.pending_minutes:
            reasons.append('long-active')
        if reasons:
            findings.append({
                'type': 'Job',
                'namespace': ns,
                'name': name,
                'fail_ratio': round(fail_ratio, 2),
                'failed': failed,
                'succeeded': succeeded,
                'active': active,
                'backoff_limit': backoff_limit,
                'reasons': reasons,
            })
    return findings


def map_cron_jobs(cronjobs):
    # Build index by owning CronJob via label or owner reference
    cj_index = {}
    for cj in cronjobs:
        cj_index.setdefault((cj.metadata.namespace, cj.metadata.name), {'cronjob': cj, 'jobs': []})
    return cj_index


def link_jobs_to_cron(jobs, cj_index):
    for j in jobs:
        owners = j.metadata.owner_references or []
        for o in owners:
            if o.kind == 'CronJob':
                key = (j.metadata.namespace, o.name)
                if key in cj_index:
                    cj_index[key]['jobs'].append(j)


def eval_cronjobs(cj_index, args) -> List[Finding]:
    results = []
    for (ns, name), data in cj_index.items():
        jobs = sorted(data['jobs'], key=lambda x: getattr(x.status.start_time, 'timestamp', None) or 0, reverse=True)
        recent = jobs[: args.cron_window]
        if not recent:
            continue
        # compute consecutive failures
        consecutive_failed = 0
        for j in recent:
            if (j.status.succeeded or 0) > 0:
                break
            if (j.status.failed or 0) > 0:
                consecutive_failed += 1
        # average fail ratio
        ratios = []
        for j in recent:
            failed = j.status.failed or 0
            succeeded = j.status.succeeded or 0
            total = failed + succeeded
            if total > 0:
                ratios.append(failed / total)
        avg_fail = sum(ratios) / len(ratios) if ratios else 0.0
        reasons = []
        if consecutive_failed >= args.cron_consecutive_failures:
            reasons.append('cron-consecutive-failures')
        if avg_fail >= args.fail_ratio and len(ratios) >= 2:
            reasons.append('cron-high-avg-fail-ratio')
        if reasons:
            results.append({
                'type': 'CronJob',
                'namespace': ns,
                'name': name,
                'consecutive_failed': consecutive_failed,
                'avg_fail_ratio': round(avg_fail, 2),
                'recent_jobs_considered': len(recent),
                'reasons': reasons,
            })
    return results


def main():
    args = parse_args()
    try:
        load_cfg()
        batch_api = client.BatchV1Api()
        jobs = collect_jobs(batch_api, args.namespace, args.max_age_hours)
        cronjobs = collect_cronjobs(batch_api, args.namespace)
        job_findings = eval_jobs(jobs, args)
        cj_index = map_cron_jobs(cronjobs)
        link_jobs_to_cron(jobs, cj_index)
        cron_findings = eval_cronjobs(cj_index, args)
        findings = job_findings + cron_findings
        if args.json:
            print(json.dumps({'findings': findings, 'count': len(findings)}, indent=2))
            return
        if not findings:
            print('No job / cronjob retry hotspots detected.')
            return
        print('# Backoff / Retry Hotspots')
        for f in findings:
            if f['type'] == 'Job':
                print(f"Job {f['namespace']}/{f['name']} fail_ratio={f['fail_ratio']} failed={f['failed']} backoff={f['failed']}/{f['backoff_limit']} reasons={','.join(f['reasons'])}")
            else:
                print(f"CronJob {f['namespace']}/{f['name']} avg_fail={f['avg_fail_ratio']} consecutive_failed={f['consecutive_failed']} reasons={','.join(f['reasons'])}")
        print('\nSuggestions:')
        for f in findings[:15]:
            if f['type'] == 'Job':
                print(f"  Investigate pod logs: kubectl logs job/{f['name']} -n {f['namespace']} --previous")
            else:
                print(f"  Check schedule or job template: kubectl describe cronjob {f['name']} -n {f['namespace']}")
        if len(findings) > 15:
            print(f"  ... {len(findings)-15} more")
    except ApiException as e:
        print(f"API Error: {e}")
        exit(1)
    except Exception as e:
        print(f"Error: {e}")
        exit(1)


if __name__ == '__main__':
    main()
