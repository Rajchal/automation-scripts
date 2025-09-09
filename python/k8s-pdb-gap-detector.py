#!/usr/bin/env python3
"""
Kubernetes PodDisruptionBudget Gap Detector

Finds Deployments & StatefulSets without any matching PodDisruptionBudget (PDB) and
flags ineffective PDB definitions.

A PDB is considered matching a workload if ALL selector labels of the PDB are present
with equal values in the workload's pod template labels.

Ineffective PDB heuristics:
  - No minAvailable and no maxUnavailable set
  - minAvailable >= replicas (cannot evict any pod)
  - maxUnavailable == 0 (same as disallowing disruption)

Output:
  - Human readable list with reasons + suggestions
  - Optional JSON via --json

Usage:
  python k8s-pdb-gap-detector.py
  python k8s-pdb-gap-detector.py --namespace prod --json

Exit codes:
  0 success (even if gaps found)
  1 API/config error
"""
from __future__ import annotations
import argparse
import json
from typing import Dict, List, Optional
from kubernetes import client, config
from kubernetes.client import ApiException

WorkloadRecord = Dict[str, object]
PDBRecord = Dict[str, object]


def load_config():
    try:
        config.load_kube_config()
    except Exception:
        config.load_incluster_config()


def parse_args():
    p = argparse.ArgumentParser(description="Detect workloads missing PodDisruptionBudgets")
    p.add_argument('--namespace', '-n', help='Restrict to single namespace')
    p.add_argument('--json', action='store_true', help='JSON output')
    return p.parse_args()


def list_workloads(apps: client.AppsV1Api, ns: Optional[str]) -> List[WorkloadRecord]:
    items: List[WorkloadRecord] = []
    if ns:
        deps = apps.list_namespaced_deployment(ns).items
        sts = apps.list_namespaced_stateful_set(ns).items
    else:
        deps = apps.list_deployment_for_all_namespaces().items
        sts = apps.list_stateful_set_for_all_namespaces().items
    for d in deps:
        items.append({
            'kind': 'Deployment',
            'namespace': d.metadata.namespace,
            'name': d.metadata.name,
            'labels': d.spec.template.metadata.labels or {},
            'replicas': (d.spec.replicas or 1),
        })
    for s in sts:
        items.append({
            'kind': 'StatefulSet',
            'namespace': s.metadata.namespace,
            'name': s.metadata.name,
            'labels': s.spec.template.metadata.labels or {},
            'replicas': (s.spec.replicas or 1),
        })
    return items


def list_pdbs(policy: client.PolicyV1Api, ns: Optional[str]) -> List[PDBRecord]:
    if ns:
        pdbs = policy.list_namespaced_pod_disruption_budget(ns).items
    else:
        pdbs = policy.list_pod_disruption_budget_for_all_namespaces().items
    records: List[PDBRecord] = []
    for p in pdbs:
        sel = (p.spec.selector.match_labels if p.spec and p.spec.selector else {}) or {}
        min_avail = getattr(p.spec, 'min_available', None)
        max_unavail = getattr(p.spec, 'max_unavailable', None)
        # Convert IntOrString objects to str then int if possible
        def norm(val):
            if val is None:
                return None
            try:
                return int(str(val))
            except ValueError:
                return str(val)
        records.append({
            'namespace': p.metadata.namespace,
            'name': p.metadata.name,
            'selector': sel,
            'minAvailable': norm(min_avail),
            'maxUnavailable': norm(max_unavail),
        })
    return records


def selector_matches(selector: Dict[str, str], labels: Dict[str, str]) -> bool:
    for k, v in selector.items():
        if labels.get(k) != v:
            return False
    return True


def evaluate(workloads: List[WorkloadRecord], pdbs: List[PDBRecord]):
    results = []
    # Index PDBs per namespace for speed
    by_ns: Dict[str, List[PDBRecord]] = {}
    for p in pdbs:
        by_ns.setdefault(p['namespace'], []).append(p)

    for w in workloads:
        ns = w['namespace']
        candidates = by_ns.get(ns, [])
        matched: List[PDBRecord] = []
        for p in candidates:
            if selector_matches(p['selector'], w['labels']):
                matched.append(p)
        if not matched:
            results.append({
                'namespace': ns,
                'workload': f"{w['kind']}/{w['name']}",
                'gap': True,
                'reason': 'no-pdb',
                'pdbs': [],
            })
        else:
            # Check effectiveness
            effective = []
            issues = []
            for p in matched:
                min_av = p['minAvailable']
                max_un = p['maxUnavailable']
                if min_av is None and max_un is None:
                    issues.append(f"{p['name']}:no-min-or-max")
                    continue
                replicas = w['replicas']
                if isinstance(min_av, int) and min_av >= replicas:
                    issues.append(f"{p['name']}:min>=replicas")
                    continue
                if isinstance(max_un, int) and max_un == 0:
                    issues.append(f"{p['name']}:max=0")
                    continue
                effective.append(p['name'])
            if issues:
                results.append({
                    'namespace': ns,
                    'workload': f"{w['kind']}/{w['name']}",
                    'gap': True,
                    'reason': 'ineffective-pdb',
                    'details': issues,
                })
            else:
                results.append({
                    'namespace': ns,
                    'workload': f"{w['kind']}/{w['name']}",
                    'gap': False,
                    'pdbs': effective,
                })
    return results


def print_human(results):
    gaps = [r for r in results if r.get('gap')]
    if not gaps:
        print('All workloads have effective PodDisruptionBudgets.')
        return
    print('# PDB Gaps / Issues')
    for r in gaps:
        if r['reason'] == 'no-pdb':
            print(f"{r['namespace']} {r['workload']} -> MISSING PDB")
        else:
            print(f"{r['namespace']} {r['workload']} -> INEFFECTIVE PDB ({','.join(r.get('details', []))})")
    print('\nSuggestions:')
    for r in gaps[:15]:
        ns = r['namespace']
        name = r['workload'].split('/',1)[1]
        print(f"kubectl create pdb {name}-pdb -n {ns} --selector=app={name} --min-available=1")
    if len(gaps) > 15:
        print(f"... {len(gaps)-15} more")


def main():
    args = parse_args()
    try:
        load_config()
        apps = client.AppsV1Api()
        policy = client.PolicyV1Api()
        workloads = list_workloads(apps, args.namespace)
        pdbs = list_pdbs(policy, args.namespace)
        results = evaluate(workloads, pdbs)
        if args.json:
            print(json.dumps({'results': results}, indent=2))
            return
        print_human(results)
    except ApiException as e:
        print(f"API Error: {e}")
        exit(1)
    except Exception as e:
        print(f"Error: {e}")
        exit(1)


if __name__ == '__main__':
    main()
