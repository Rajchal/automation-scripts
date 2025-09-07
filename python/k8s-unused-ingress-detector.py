#!/usr/bin/env python3
"""
Kubernetes Unused Ingress Detector

Identifies Ingress resources that appear unused because:
  * They reference Services that don't exist OR
  * All referenced Services have zero ready endpoints OR
  * (Optional future enhancement) No recent traffic annotation (not implemented)

Checks across all namespaces (default) or a target namespace.

Logic:
  1. Collect all Services (namespace -> name)
  2. Build a map of Service -> has_ready_endpoints using Endpoints/EndpointSlice
  3. For each Ingress rule/backend determine if any live backend exists
  4. Report Ingress as unused if NO backend resolves to an existing Service with ready endpoints

Exclusions:
  - kube-system namespace unless --include-system

Usage:
  python k8s-unused-ingress-detector.py
  python k8s-unused-ingress-detector.py -n my-namespace
  python k8s-unused-ingress-detector.py --json

Exit codes:
  0 success
  1 API/config error
"""
from __future__ import annotations
import argparse
import json
from typing import Dict, Set
from kubernetes import client, config
from kubernetes.client import ApiException

SYSTEM_NAMESPACES = {"kube-system", "kube-public", "kube-node-lease"}


def load_config():
    try:
        config.load_kube_config()
    except Exception:
        config.load_incluster_config()


def get_services(core: client.CoreV1Api, namespace: str | None):
    if namespace:
        svcs = core.list_namespaced_service(namespace).items
    else:
        svcs = core.list_service_for_all_namespaces().items
    return {(s.metadata.namespace, s.metadata.name): s for s in svcs}


def endpoints_ready(core: client.CoreV1Api, namespace: str | None) -> Set[tuple[str, str]]:
    ready: Set[tuple[str, str]] = set()
    if namespace:
        eps = core.list_namespaced_endpoints(namespace).items
    else:
        eps = core.list_endpoints_for_all_namespaces().items
    for ep in eps:
        ns = ep.metadata.namespace
        name = ep.metadata.name
        subsets = ep.subsets or []
        for sub in subsets:
            addrs = sub.addresses or []
            if addrs:
                ready.add((ns, name))
                break
    return ready


def analyze_ingresses(networking: client.NetworkingV1Api, services: Dict[tuple, object], ready_eps: Set[tuple[str, str]], namespace: str | None):
    if namespace:
        ingresses = networking.list_namespaced_ingress(namespace).items
    else:
        ingresses = networking.list_ingress_for_all_namespaces().items
    unused = []
    details = []
    for ing in ingresses:
        ns = ing.metadata.namespace
        if ns in SYSTEM_NAMESPACES and namespace is None:
            continue
        backends = []
        # Default backend
        if ing.spec and ing.spec.default_backend and ing.spec.default_backend.service:
            svc_name = ing.spec.default_backend.service.name
            backends.append(svc_name)
        # Rules
        for rule in (ing.spec.rules or []):
            if not rule.http:
                continue
            for path in (rule.http.paths or []):
                if path.backend and path.backend.service and path.backend.service.name:
                    backends.append(path.backend.service.name)
        if not backends:
            unused.append((ns, ing.metadata.name, 'no-backends-defined'))
            continue
        any_live = False
        missing_svcs = []
        no_ready = []
        for svc_name in backends:
            key = (ns, svc_name)
            if key not in services:
                missing_svcs.append(svc_name)
                continue
            if key not in ready_eps:
                no_ready.append(svc_name)
            else:
                any_live = True
        if not any_live:
            reason = []
            if missing_svcs:
                reason.append(f"missing:{','.join(sorted(set(missing_svcs)))})")
            if no_ready:
                reason.append(f"no-ready:{','.join(sorted(set(no_ready)))}")
            unused.append((ns, ing.metadata.name, ';'.join(reason) or 'no-live-backends'))
        details.append({
            'namespace': ns,
            'name': ing.metadata.name,
            'backends': backends,
            'unused': not any_live,
        })
    return unused, details


def main():
    parser = argparse.ArgumentParser(description="Detect Ingress resources with no active backends")
    parser.add_argument('-n', '--namespace', help='Limit to single namespace')
    parser.add_argument('--include-system', action='store_true', help='Include system namespaces')
    parser.add_argument('--json', action='store_true', help='JSON output')
    args = parser.parse_args()

    try:
        load_config()
        core = client.CoreV1Api()
        networking = client.NetworkingV1Api()

        services = get_services(core, args.namespace)
        ready = endpoints_ready(core, args.namespace)
        unused, details = analyze_ingresses(networking, services, ready, args.namespace)

        if not args.include_system and not args.namespace:
            unused = [u for u in unused if u[0] not in SYSTEM_NAMESPACES]
            details = [d for d in details if d['namespace'] not in SYSTEM_NAMESPACES]

        if args.json:
            print(json.dumps({'unused': [
                {'namespace': ns, 'name': name, 'reason': reason} for ns, name, reason in unused
            ], 'details': details}, indent=2))
            return

        if not unused:
            print('No unused Ingress resources detected.')
            return
        print('# Unused Ingresses')
        for ns, name, reason in unused:
            print(f"{ns}/{name} -> {reason}")
        print('\nCleanup suggestions (verify before deleting):')
        for ns, name, _ in unused:
            print(f"kubectl delete ingress {name} -n {ns}")
    except ApiException as e:
        print(f"API Error: {e}")
        exit(1)
    except Exception as e:
        print(f"Error: {e}")
        exit(1)


if __name__ == '__main__':
    main()
