#!/usr/bin/env python3
"""
Kubernetes Stuck Finalizer Detector / Cleaner Helper

Scans common workload & infra resource kinds for objects that:
  1. Have metadata.deletionTimestamp set (they are terminating)
  2. Still retain one or more finalizers after a configurable threshold

These are often "stuck" because the controller responsible for removing the
finalizer is gone or failing. This script ONLY prints recommended kubectl patch
commands; it does NOT modify the cluster.

Kinds covered (cluster‑wide scan):
  - Namespaces (cluster-scoped)
  - Pods
  - PersistentVolumeClaims
  - Deployments
  - StatefulSets
  - DaemonSets
  - Jobs

Usage:
  python k8s-stuck-finalizer-cleaner.py [--threshold-seconds 600] [--kinds Pods,Namespaces,...] \
       [--namespace-filter ns1,ns2] [--include-system]

Flags:
  --threshold-seconds    Age (seconds since deletionTimestamp) to consider stuck (default 600)
  --kinds                Comma list subset (case-insensitive) of: namespace,pod,persistentvolumeclaim,deployment,statefulset,daemonset,job
  --namespace-filter     Only consider these (comma list) namespaces for namespaced kinds
  --include-system       Include kube-system, kube-public, kube-node-lease (excluded by default)
  --show-nonstuck        Also list terminating objects not yet past threshold

Exit codes:
  0 success (even if none found)
  1 API/config error

Generated patch suggestion (verify before executing):
  kubectl patch <resource> <name> [-n <ns>] -p '{"metadata":{"finalizers":[]}}' --type=merge

NOTE: Force-removing finalizers can cause leakage of external resources. Always
      validate that the finalizer's controller is truly dead or irrecoverable.
"""
from __future__ import annotations
import argparse
import datetime as dt
from typing import Dict, List, Tuple
from kubernetes import client, config
from kubernetes.client import ApiException

# Namespaces we usually exclude to reduce noise
SYSTEM_NAMESPACES = {"kube-system", "kube-public", "kube-node-lease"}

# Mapping of canonical Kind -> (plural, is_namespaced)
KIND_META: Dict[str, Tuple[str, bool]] = {
    "NAMESPACE": ("namespaces", False),
    "POD": ("pods", True),
    "PERSISTENTVOLUMECLAIM": ("persistentvolumeclaims", True),
    "DEPLOYMENT": ("deployments", True),
    "STATEFULSET": ("statefulsets", True),
    "DAEMONSET": ("daemonsets", True),
    "JOB": ("jobs", True),
}


def load_kube_config():
    """Try regular kubeconfig then in-cluster."""
    try:
        config.load_kube_config()
    except Exception:
        config.load_incluster_config()


def parse_args():
    p = argparse.ArgumentParser(description="Detect stuck Kubernetes finalizers")
    p.add_argument("--threshold-seconds", type=int, default=600,
                   help="Age (seconds) after deletionTimestamp to treat as stuck (default 600)")
    p.add_argument("--kinds", help="Comma list subset of kinds to scan", default="")
    p.add_argument("--namespace-filter", help="Comma list of namespaces to include (namespaced kinds only)", default="")
    p.add_argument("--include-system", action="store_true", help="Include system namespaces")
    p.add_argument("--show-nonstuck", action="store_true", help="Also show terminating objects not yet past threshold")
    return p.parse_args()


def to_kind_set(kinds_arg: str):
    if not kinds_arg.strip():
        return set(KIND_META.keys())
    wanted = {k.strip().upper() for k in kinds_arg.split(',') if k.strip()}
    return {k for k in KIND_META if k in wanted}


def parse_namespace_filter(ns_arg: str):
    return {n.strip() for n in ns_arg.split(',') if n.strip()} if ns_arg else set()


def parse_rfc3339(ts: str) -> dt.datetime:
    # Kubernetes timestamps are RFC3339, often ending with 'Z'
    if ts.endswith('Z'):
        ts = ts[:-1] + '+00:00'
    return dt.datetime.fromisoformat(ts)


def age_seconds(ts: str) -> float:
    try:
        dt_ts = parse_rfc3339(ts)
        now = dt.datetime.now(dt.timezone.utc)
        # Ensure aware
        if dt_ts.tzinfo is None:
            dt_ts = dt_ts.replace(tzinfo=dt.timezone.utc)
        return (now - dt_ts).total_seconds()
    except Exception:
        return -1.0


def scan(core: client.CoreV1Api, apps: client.AppsV1Api, batch: client.BatchV1Api, kinds, ns_filter, include_system, threshold):
    stuck = []  # list of dict
    terminating = []

    def consider(obj, kind: str, is_ns: bool):
        meta = obj.metadata
        if not meta:
            return
        ns = meta.namespace or "" if is_ns else None
        if is_ns and not include_system and ns in SYSTEM_NAMESPACES:
            return
        if is_ns and ns_filter and ns not in ns_filter:
            return
        if not is_ns and kind == 'NAMESPACE':  # cluster scoped already handled
            pass
        if meta.deletion_timestamp:
            if meta.finalizers:
                age = age_seconds(meta.deletion_timestamp)
                record = {
                    'kind': kind.capitalize(),
                    'name': meta.name,
                    'namespace': ns if is_ns else None,
                    'finalizers': list(meta.finalizers),
                    'age_seconds': age,
                    'deletion_timestamp': meta.deletion_timestamp,
                }
                if age >= threshold or age < 0:
                    stuck.append(record)
                else:
                    terminating.append(record)

    # Namespaces
    if 'NAMESPACE' in kinds:
        for ns in core.list_namespace().items:
            consider(ns, 'NAMESPACE', False)

    # Pods
    if 'POD' in kinds:
        for pod in core.list_pod_for_all_namespaces().items:
            consider(pod, 'POD', True)

    # PVCs
    if 'PERSISTENTVOLUMECLAIM' in kinds:
        for pvc in core.list_persistent_volume_claim_for_all_namespaces().items:
            consider(pvc, 'PERSISTENTVOLUMECLAIM', True)

    # Deployments
    if 'DEPLOYMENT' in kinds:
        for dep in apps.list_deployment_for_all_namespaces().items:
            consider(dep, 'DEPLOYMENT', True)

    # StatefulSets
    if 'STATEFULSET' in kinds:
        for sts in apps.list_stateful_set_for_all_namespaces().items:
            consider(sts, 'STATEFULSET', True)

    # DaemonSets
    if 'DAEMONSET' in kinds:
        for ds in apps.list_daemon_set_for_all_namespaces().items:
            consider(ds, 'DAEMONSET', True)

    # Jobs
    if 'JOB' in kinds:
        for job in batch.list_job_for_all_namespaces().items:
            consider(job, 'JOB', True)

    return stuck, terminating


def print_report(stuck, terminating, threshold, show_nonstuck):
    print(f"Threshold for stuck: >= {threshold}s since deletionTimestamp\n")

    if not stuck:
        print("No stuck finalizers detected.")
    else:
        print("Stuck resources:")
        for r in stuck:
            ns_part = f"{r['namespace']}/" if r['namespace'] else ""
            fins = ','.join(r['finalizers'])
            age = int(r['age_seconds']) if r['age_seconds'] >= 0 else 'n/a'
            print(f"  {r['kind']} {ns_part}{r['name']} finalizers=[{fins}] age={age}s")
        print("\nPatch suggestions (verify necessity!):")
        for r in stuck:
            plural = KIND_META[r['kind'].upper()][0] if r['kind'].upper() in KIND_META else r['kind'].lower() + 's'
            base = f"kubectl patch {plural.rstrip('s')} {r['name']}"
            if r['namespace']:
                base += f" -n {r['namespace']}"
            print(base + " -p '{\"metadata\":{\"finalizers\":[]}}' --type=merge")

    if show_nonstuck and terminating:
        print("\nTerminating (not yet past threshold):")
        for r in terminating:
            ns_part = f"{r['namespace']}/" if r['namespace'] else ""
            fins = ','.join(r['finalizers'])
            age = int(r['age_seconds']) if r['age_seconds'] >= 0 else 'n/a'
            print(f"  {r['kind']} {ns_part}{r['name']} finalizers=[{fins}] age={age}s")

    print("\nSummary:")
    print(f"  Stuck: {len(stuck)}")
    if show_nonstuck:
        print(f"  Terminating (< threshold): {len(terminating)}")


def main():
    args = parse_args()
    kinds = to_kind_set(args.kinds)
    ns_filter = parse_namespace_filter(args.namespace_filter)

    try:
        load_kube_config()
        core = client.CoreV1Api()
        apps = client.AppsV1Api()
        batch = client.BatchV1Api()
        stuck, terminating = scan(core, apps, batch, kinds, ns_filter, args.include_system, args.threshold_seconds)
        print_report(stuck, terminating, args.threshold_seconds, args.show_nonstuck)
    except ApiException as e:
        print(f"API Error: {e}")
        exit(1)
    except Exception as e:
        print(f"Error: {e}")
        exit(1)


if __name__ == '__main__':
    main()
