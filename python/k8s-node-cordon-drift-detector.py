#!/usr/bin/env python3
"""
Kubernetes Node Cordon Drift Detector

Purpose:
  Report nodes that have been cordoned (spec.unschedulable == True) longer than a
  threshold without an acceptable reason annotation. Helps catch forgotten
  maintenance cordons that reduce cluster scheduling capacity.

Heuristics & Approach:
  - A node is considered cordoned if spec.unschedulable is True.
  - Kubernetes does not store the cordon timestamp directly; we attempt to infer
    it from the most recent Event with reason "NodeNotSchedulable" or
    "NodeSchedulable" (the former marks cordon time, the latter would reset).
  - If no relevant event is found, the age is reported as "unknown" and the node
    is still flagged if unschedulable and missing a reason annotation.
  - Acceptable reason annotations (override with --reason-annotation-keys):
       maintenance-reason
       node.kubernetes.io/cordon-reason
       cordon-reason
       cluster.ops/cordon-reason

Flags:
  --threshold-hours <int>         Minimum age (in hours) cordoned before flagging (default 4)
  --reason-annotation-keys <list> Comma list of annotation keys treated as valid justification
  --all                           Show all cordoned nodes (even if annotated / below threshold)
  --json                          Output JSON instead of human-readable text
  --max-events <int>              Max events to scan (default 5000) for performance control

Exit Codes:
  0 success
  1 API / config error

Examples:
  python k8s-node-cordon-drift-detector.py
  python k8s-node-cordon-drift-detector.py --threshold-hours 1 --all
  python k8s-node-cordon-drift-detector.py --reason-annotation-keys=maintenance-reason,ops/cordon --json

Notes:
  - Event scanning can be large in busy clusters; adjust --max-events if needed.
  - Always verify before uncordoning: node may be intentionally offline.
"""
from __future__ import annotations
import argparse
import datetime as dt
import json
from typing import Dict, List, Optional
from kubernetes import client, config
from kubernetes.client import ApiException

DEFAULT_REASON_KEYS = [
    "maintenance-reason",
    "node.kubernetes.io/cordon-reason",
    "cordon-reason",
    "cluster.ops/cordon-reason",
]


def load_config():
    try:
        config.load_kube_config()
    except Exception:
        # Fallback to in-cluster
        config.load_incluster_config()


def parse_args():
    p = argparse.ArgumentParser(description="Detect forgotten cordoned nodes")
    p.add_argument("--threshold-hours", type=int, default=4,
                   help="Minimum hours cordoned before flagging (default 4)")
    p.add_argument("--reason-annotation-keys", default=",".join(DEFAULT_REASON_KEYS),
                   help="Comma list of acceptable reason annotation keys")
    p.add_argument("--all", action="store_true", help="Show all cordoned nodes regardless of threshold / annotation")
    p.add_argument("--json", action="store_true", help="Output JSON only")
    p.add_argument("--max-events", type=int, default=5000, help="Max events to scan (default 5000)")
    return p.parse_args()


def parse_rfc3339(ts: str) -> Optional[dt.datetime]:
    if not ts:
        return None
    try:
        if ts.endswith('Z'):
            ts = ts[:-1] + '+00:00'
        dt_obj = dt.datetime.fromisoformat(ts)
        if dt_obj.tzinfo is None:
            dt_obj = dt_obj.replace(tzinfo=dt.timezone.utc)
        return dt_obj.astimezone(dt.timezone.utc)
    except Exception:
        return None


def hours_since(ts: Optional[dt.datetime]) -> Optional[float]:
    if not ts:
        return None
    now = dt.datetime.now(dt.timezone.utc)
    return (now - ts).total_seconds() / 3600.0


def build_event_index(core: client.CoreV1Api, max_events: int) -> Dict[str, List[client.V1Event]]:
    # Events are namespaced; we pull all and slice for performance.
    events = core.list_event_for_all_namespaces(limit=max_events).items or []
    idx: Dict[str, List[client.V1Event]] = {}
    for ev in events:
        involved = getattr(ev, 'involved_object', None)
        if not involved or involved.kind != 'Node':
            continue
        name = involved.name
        idx.setdefault(name, []).append(ev)
    # Sort each list by lastTimestamp / eventTime descending
    for name, lst in idx.items():
        def ev_time(e):
            return parse_rfc3339(e.last_timestamp or e.event_time or e.first_timestamp or "") or dt.datetime.fromtimestamp(0, tz=dt.timezone.utc)
        lst.sort(key=ev_time, reverse=True)
    return idx


def infer_cordon_time(node_name: str, events: List[client.V1Event]) -> Optional[dt.datetime]:
    # Look for the most recent NodeNotSchedulable event before any NodeSchedulable.
    cordon_time = None
    for ev in events:
        reason = ev.reason or ""
        t = parse_rfc3339(ev.last_timestamp or ev.event_time or ev.first_timestamp or "")
        if reason == 'NodeSchedulable':
            # We hit an uncordon event before finding cordon => current cordon likely newer than events scanned
            break
        if reason == 'NodeNotSchedulable':
            cordon_time = t
            break
    return cordon_time


def audit_nodes(core: client.CoreV1Api, threshold_hours: int, reason_keys: List[str], show_all: bool, max_events: int):
    nodes = core.list_node().items
    event_index = build_event_index(core, max_events=max_events)

    findings = []
    for n in nodes:
        if not n.spec or not getattr(n.spec, 'unschedulable', False):
            continue
        name = n.metadata.name
        annotations = n.metadata.annotations or {}
        reason_annotation_key = next((k for k in reason_keys if k in annotations and annotations[k].strip()), None)
        reason_value = annotations.get(reason_annotation_key, "") if reason_annotation_key else ""

        events = event_index.get(name, [])
        cordon_time = infer_cordon_time(name, events)
        age_hours = hours_since(cordon_time) if cordon_time else None

        over_threshold = (age_hours is not None and age_hours >= threshold_hours) or (cordon_time is None and reason_annotation_key is None)
        needs_attention = (over_threshold and not reason_annotation_key)

        if show_all or needs_attention:
            findings.append({
                'node': name,
                'age_hours': round(age_hours, 2) if age_hours is not None else None,
                'reason_annotation_key': reason_annotation_key,
                'reason': reason_value,
                'needs_attention': needs_attention,
                'cordon_time': cordon_time.isoformat() if cordon_time else None,
            })

    return findings


def print_report(findings, threshold_hours: int, json_mode: bool):
    if json_mode:
        print(json.dumps({'threshold_hours': threshold_hours, 'findings': findings}, indent=2))
        return

    print(f"Cordon drift threshold: {threshold_hours}h\n")
    if not findings:
        print("No cordon drift detected.")
        return

    print("Cordoned Nodes:")
    for f in findings:
        age = f['age_hours'] if f['age_hours'] is not None else 'unknown'
        reason = f['reason'] or 'None'
        status = 'ATTENTION' if f['needs_attention'] else 'ok'
        print(f"  {f['node']}: age={age}h reason={reason} status={status}")

    print("\nSuggestions (verify necessity):")
    for f in findings:
        if f['needs_attention']:
            if f['reason_annotation_key'] is None:
                print(f"  # Missing annotation; add one or uncordon")
                print(f"  kubectl annotate node {f['node']} maintenance-reason='Completed maintenance' --overwrite")
            print(f"  kubectl uncordon {f['node']}")


def main():
    args = parse_args()
    reason_keys = [k.strip() for k in args.reason_annotation_keys.split(',') if k.strip()]

    try:
        load_config()
        core = client.CoreV1Api()
        findings = audit_nodes(core, args.threshold_hours, reason_keys, args.all, args.max_events)
        print_report(findings, args.threshold_hours, args.json)
    except ApiException as e:
        print(f"API Error: {e}")
        exit(1)
    except Exception as e:
        print(f"Error: {e}")
        exit(1)


if __name__ == '__main__':
    main()
