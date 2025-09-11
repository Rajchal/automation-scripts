#!/usr/bin/env python3
"""
Kubernetes Headless Service Unused Detector

Identifies headless Services (spec.clusterIP == 'None') that appear unused because:
  * They have no selector labels (and thus likely rely on manual Endpoints) AND current Endpoints object is missing or empty
  * OR they have a selector but zero Pods match it
  * OR they have Endpoints object with zero ready addresses

Outputs a list plus optional JSON and cleanup command suggestions.

Usage:
  python k8s-service-headless-unused-detector.py
  python k8s-service-headless-unused-detector.py -n my-namespace --json

Exit codes:
  0 success
  1 API/config error
"""
from __future__ import annotations
import argparse
import json
from typing import Dict, List, Set
from kubernetes import client, config
from kubernetes.client import ApiException

SYSTEM_NAMESPACES = {"kube-system", "kube-public", "kube-node-lease"}


def load_config():
    try:
        config.load_kube_config()
    except Exception:
        config.load_incluster_config()


def list_headless_services(v1: client.CoreV1Api, ns: str | None):
    if ns:
        svcs = v1.list_namespaced_service(ns).items
    else:
        svcs = v1.list_service_for_all_namespaces().items
    return [s for s in svcs if s.spec.cluster_ip == 'None']


def map_pods(v1: client.CoreV1Api, ns: str | None):
    if ns:
        pods = v1.list_namespaced_pod(ns).items
    else:
        pods = v1.list_pod_for_all_namespaces().items
    per_ns = {}
    for p in pods:
        per_ns.setdefault(p.metadata.namespace, []).append(p)
    return per_ns


def endpoints_map(v1: client.CoreV1Api, ns: str | None):
    if ns:
        eps = v1.list_namespaced_endpoints(ns).items
    else:
        eps = v1.list_endpoints_for_all_namespaces().items
    m = {}
    for e in eps:
        m[(e.metadata.namespace, e.metadata.name)] = e
    return m


def selector_matches(selector: Dict[str, str], pod_labels: Dict[str, str]) -> bool:
    for k, v in selector.items():
        if pod_labels.get(k) != v:
            return False
    return True


def analyze(headless, pods_by_ns, ep_map, include_system: bool):
    findings = []
    for s in headless:
        ns = s.metadata.namespace
        if not include_system and ns in SYSTEM_NAMESPACES:
            continue
        selector = s.spec.selector or {}
        key = (ns, s.metadata.name)
        ep = ep_map.get(key)
        # Count ready addresses
        ready_addrs = 0
        if ep and ep.subsets:
            for sub in ep.subsets:
                if sub.addresses:
                    ready_addrs += len(sub.addresses)
        matched_pods = []
        if selector:
            for p in pods_by_ns.get(ns, []):
                if selector_matches(selector, p.metadata.labels or {}):
                    matched_pods.append(p)
        reason_parts = []
        if not selector and (ready_addrs == 0):
            reason_parts.append('no-selector-no-ready-endpoints')
        if selector and not matched_pods:
            reason_parts.append('selector-zero-pods')
        if ready_addrs == 0:
            reason_parts.append('no-ready-endpoints')
        if reason_parts:
            findings.append({
                'namespace': ns,
                'service': s.metadata.name,
                'reasons': list(sorted(set(reason_parts))),
                'selector': selector,
                'pod_matches': len(matched_pods),
                'ready_endpoints': ready_addrs,
            })
    return findings


def main():
    ap = argparse.ArgumentParser(description='Detect unused headless services')
    ap.add_argument('-n', '--namespace', help='Limit to a namespace')
    ap.add_argument('--include-system', action='store_true', help='Include system namespaces')
    ap.add_argument('--json', action='store_true', help='JSON output')
    args = ap.parse_args()
    try:
        load_config()
        v1 = client.CoreV1Api()
        headless = list_headless_services(v1, args.namespace)
        pods_by_ns = map_pods(v1, args.namespace)
        ep_map = endpoints_map(v1, args.namespace)
        findings = analyze(headless, pods_by_ns, ep_map, args.include_system)
        if args.json:
            print(json.dumps({'findings': findings, 'count': len(findings)}, indent=2))
            return
        if not findings:
            print('No unused headless services detected.')
            return
        print('# Unused / Suspect Headless Services')
        for f in findings:
            print(f"{f['namespace']}/{f['service']} reasons={','.join(f['reasons'])} pods={f['pod_matches']} ready_eps={f['ready_endpoints']}")
        print('\nCleanup suggestions (verify manually):')
        for f in findings[:25]:
            print(f"kubectl delete service {f['service']} -n {f['namespace']}")
        if len(findings) > 25:
            print(f"... {len(findings)-25} more")
    except ApiException as e:
        print(f"API Error: {e}")
        exit(1)
    except Exception as e:
        print(f"Error: {e}")
        exit(1)


if __name__ == '__main__':
    main()
