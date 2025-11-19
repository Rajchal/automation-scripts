#!/usr/bin/env python3
"""
k8s-pod-restart-spike-auditor.py

Purpose:
  Identify Kubernetes pods whose containers exhibit unusually high restart counts relative to
  a configurable age window. Useful for surfacing crash loop patterns, instability, or resource
  constraints early. Optionally annotate flagged pods (dry-run by default).

Heuristics:
  A pod is flagged if ANY container restartCount >= --min-restarts AND pod age (hours) <= --max-age-hours.
  You can also flag older pods with high restarts using --include-older (disables age filter; only restarts threshold applies).

Features:
  - Scans all namespaces or a provided subset (--namespaces)
  - Exclusion with --exclude-namespace (repeat)
  - Optional label selector (--label-selector) applied to pod list calls
  - Threshold flags: --min-restarts (default 5), --max-age-hours (default 24)
  - Annotation action: --apply-annotate with --annotation-key/--annotation-value and cap --max-annotate
  - JSON output via --json
  - CI integration: --ci-exit-on-findings returns exit code 2 if any pods flagged

Safety:
  - Only adds/merges an annotation when explicitly requested; no deletions or spec changes.
  - Dry-run by default unless --apply-annotate provided.

Requirements:
  - Kubernetes Python client library (kubernetes)
  - KUBECONFIG env pointing to a cluster OR in-cluster execution context

Examples:
  python k8s-pod-restart-spike-auditor.py --json
  python k8s-pod-restart-spike-auditor.py --min-restarts 10 --max-age-hours 12 --apply-annotate --max-annotate 30
  python k8s-pod-restart-spike-auditor.py --namespaces prod staging --label-selector app=my-api

Exit Codes:
  0 success
  1 unexpected error
  2 findings (when --ci-exit-on-findings used)
"""
import argparse
import datetime as dt
import json
import sys
from typing import Any, Dict, List, Optional

try:
    from kubernetes import client, config
except ImportError:
    client = None  # type: ignore
    config = None  # type: ignore


def parse_args():
    p = argparse.ArgumentParser(description="Audit Kubernetes pods for restart spikes (dry-run by default)")
    p.add_argument("--namespaces", nargs="*", help="Namespaces to include (default: all)")
    p.add_argument("--exclude-namespace", action="append", help="Namespaces to exclude (repeat)")
    p.add_argument("--label-selector", help="Label selector for pods (e.g. app=my-api)")
    p.add_argument("--min-restarts", type=int, default=5, help="Minimum container restartCount to flag (default: 5)")
    p.add_argument("--max-age-hours", type=int, default=24, help="Maximum pod age in hours for flagging (default: 24)")
    p.add_argument("--include-older", action="store_true", help="If set, ignore pod age filter (flag by restarts only)")
    p.add_argument("--apply-annotate", action="store_true", help="Annotate flagged pods (dry-run by default)")
    p.add_argument("--annotation-key", default="ops/restart-spike", help="Annotation key (default: ops/restart-spike)")
    p.add_argument("--annotation-value", default="true", help="Annotation value (default: true)")
    p.add_argument("--max-annotate", type=int, default=100, help="Max pods to annotate (default: 100)")
    p.add_argument("--ci-exit-on-findings", action="store_true", help="Exit code 2 if findings exist (CI mode)")
    p.add_argument("--json", action="store_true", help="JSON output")
    return p.parse_args()


def load_kube_config():
    if config is None:
        raise RuntimeError("kubernetes library not installed; pip install kubernetes")
    try:
        config.load_incluster_config()
    except Exception:
        # Fallback to local kubeconfig
        config.load_kube_config()


def pod_age_hours(pod) -> float:
    ts = pod.metadata.creation_timestamp
    if not ts:
        return 0.0
    if ts.tzinfo:
        ts = ts.astimezone(dt.timezone.utc).replace(tzinfo=None)
    now = dt.datetime.utcnow()
    delta = now - ts
    return delta.total_seconds() / 3600.0


def annotate_pod(v1: client.CoreV1Api, pod, key: str, value: str) -> Optional[str]:
    try:
        meta = pod.metadata
        anns = meta.annotations or {}
        anns[key] = value
        body = {"metadata": {"annotations": anns}}
        v1.patch_namespaced_pod(meta.name, meta.namespace, body)
        return None
    except Exception as e:
        return str(e)


def main():
    args = parse_args()
    if client is None:
        print("ERROR: kubernetes library missing; install with pip install kubernetes", file=sys.stderr)
        return 1
    try:
        load_kube_config()
    except Exception as e:
        print(f"ERROR loading Kubernetes configuration: {e}", file=sys.stderr)
        return 1

    v1 = client.CoreV1Api()

    include_namespaces = set(args.namespaces or [])
    exclude_namespaces = set(args.exclude_namespace or [])

    # If namespaces not provided, list all
    if not include_namespaces:
        try:
            ns_list = v1.list_namespace()
            for ns in ns_list.items:
                name = ns.metadata.name
                if name in exclude_namespaces:
                    continue
                include_namespaces.add(name)
        except Exception as e:
            print(f"ERROR listing namespaces: {e}", file=sys.stderr)
            return 1

    findings: List[Dict[str, Any]] = []
    annotated = 0

    for ns in sorted(include_namespaces):
        if ns in exclude_namespaces:
            continue
        try:
            pods = v1.list_namespaced_pod(ns, label_selector=args.label_selector) if args.label_selector else v1.list_namespaced_pod(ns)
        except Exception as e:
            print(f"WARN namespace {ns} list pods failed: {e}", file=sys.stderr)
            continue
        for pod in pods.items:
            age_h = pod_age_hours(pod)
            statuses = (pod.status.container_statuses or []) if pod.status else []
            if not statuses:
                continue
            max_restart = max((s.restart_count for s in statuses), default=0)
            if max_restart < args.min_restarts:
                continue
            if (not args.include_older) and (age_h > args.max_age_hours):
                continue
            containers = [s.name for s in statuses if s.restart_count >= args.min_restarts]
            rec = {
                "namespace": ns,
                "pod": pod.metadata.name,
                "age_hours": age_h,
                "max_restart": max_restart,
                "containers_flagged": containers,
                "annotate_attempted": False,
                "annotate_error": None,
            }
            if args.apply_annotate and annotated < args.max_annotate:
                err = annotate_pod(v1, pod, args.annotation_key, args.annotation_value)
                rec["annotate_attempted"] = True
                rec["annotate_error"] = err
                if err is None:
                    annotated += 1
            findings.append(rec)

    payload = {
        "min_restarts": args.min_restarts,
        "max_age_hours": args.max_age_hours,
        "include_older": args.include_older,
        "apply_annotate": args.apply_annotate,
        "annotated": annotated,
        "results": findings,
    }

    if args.json:
        print(json.dumps(payload, indent=2))
        if args.ci_exit_on_findings and findings:
            return 2
        return 0

    if not findings:
        print("No pods matched restart spike criteria under current thresholds.")
        return 0

    header = ["Namespace", "Pod", "AgeH", "MaxRestart", "Containers", "Annotated"]
    rows = [header]
    for r in findings:
        rows.append([
            r["namespace"], r["pod"], f"{r['age_hours']:.1f}", r["max_restart"], ','.join(r["containers_flagged"]) or '-',
            ("Y" if r["annotate_attempted"] and not r["annotate_error"] else ("ERR" if r["annotate_error"] else "N")),
        ])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = '  '.join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print('  '.join('-' * w for w in widths))
        else:
            print(line)

    if not args.apply_annotate:
        print("\nDry-run. Use --apply-annotate to add an annotation to flagged pods.")

    if args.ci_exit_on_findings and findings:
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
