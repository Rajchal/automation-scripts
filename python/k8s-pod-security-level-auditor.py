#!/usr/bin/env python3
"""
Kubernetes Pod Security Level Auditor

Audits running Pods for violations of Pod Security Standards (Baseline / Restricted)
by examining pod & container securityContext and spec fields.

Checks Implemented (each produces a reason code):
  hostNetwork               -> host-network
  hostPID                   -> host-pid
  hostIPC                   -> host-ipc
  privileged container      -> privileged
  allowPrivilegeEscalation  -> allow-priv-escalation
  runAsUser=0 (effective root) without runAsNonRoot true -> root-user
  missing runAsNonRoot (restricted mode) -> missing-run-as-non-root
  added Linux capabilities (any beyond NET_BIND_SERVICE) -> extra-cap
  hostPath volume usage     -> hostpath-volume
  runAsGroup=0              -> root-group
  fsGroup=0                 -> root-fsgroup
  seccompProfile unset or != RuntimeDefault/Localhost -> seccomp-unset
  readOnlyRootFilesystem false/missing (restricted) -> writable-rootfs
  apparmor disabled (if annotation container.apparmor.security.beta.kubernetes.io/<ctr> = unconfined) -> apparmor-unconfined

Exit Codes:
 0 success
 1 API/config error

Usage:
  python k8s-pod-security-level-auditor.py               # human output
  python k8s-pod-security-level-auditor.py --namespace prod --json
  python k8s-pod-security-level-auditor.py --restricted-only

Flags:
  --namespace / -n        Limit to a single namespace
  --json                  JSON output
  --restricted-only       Only emit findings that violate "restricted" profile (suppress baseline-only issues)
  --include-system        Include kube-system & other system namespaces

Notes:
  - This is a best-effort static inspection (does not query runtime seccomp/apparmor if unset in spec).
  - For capabilities, NET_BIND_SERVICE is tolerated; all others flagged.
  - Baseline vs Restricted (loosely): host* fields baseline violation; privilege escalations restricted.
"""
from __future__ import annotations
import argparse
import json
from typing import List, Dict, Any
from kubernetes import client, config
from kubernetes.client import ApiException

SYSTEM_NAMESPACES = {"kube-system", "kube-public", "kube-node-lease"}
TOLERATED_CAPS = {"NET_BIND_SERVICE"}

Finding = Dict[str, Any]


def load_kube():
    try:
        config.load_kube_config()
    except Exception:
        config.load_incluster_config()


def parse_args():
    p = argparse.ArgumentParser(description="Audit pod security context vs Pod Security Standards")
    p.add_argument('--namespace', '-n', help='Namespace to scan (default all)')
    p.add_argument('--json', action='store_true', help='JSON output')
    p.add_argument('--restricted-only', action='store_true', help='Only show restricted profile violations')
    p.add_argument('--include-system', action='store_true', help='Include system namespaces')
    return p.parse_args()


# Classification of reasons roughly into baseline vs restricted severity
BASELINE_ONLY = {"host-network", "host-pid", "host-ipc", "hostpath-volume"}
RESTRICTED_LEVEL = {
    "privileged", "allow-priv-escalation", "root-user", "missing-run-as-non-root", "extra-cap",
    "root-group", "root-fsgroup", "seccomp-unset", "writable-rootfs", "apparmor-unconfined"
}


def classify(reason: str) -> str:
    if reason in RESTRICTED_LEVEL:
        return 'restricted'
    return 'baseline'


def collect_findings(pods, restricted_only: bool, include_system: bool) -> List[Finding]:
    findings: List[Finding] = []
    for pod in pods:
        ns = pod.metadata.namespace
        if not include_system and ns in SYSTEM_NAMESPACES:
            continue
        pod_sc = pod.spec.security_context or client.V1PodSecurityContext()
        fs_group = getattr(pod_sc, 'fs_group', None)
        secc_profile_pod = getattr(pod_sc, 'seccomp_profile', None)
        pod_level_cap_add = []  # rarely used
        has_host_path = any(v.host_path is not None for v in (pod.spec.volumes or []))
        if has_host_path:
            findings.append(_make(pod, None, 'hostpath-volume'))
        if pod.spec.host_network:
            findings.append(_make(pod, None, 'host-network'))
        if pod.spec.host_pid:
            findings.append(_make(pod, None, 'host-pid'))
        if pod.spec.host_ipc:
            findings.append(_make(pod, None, 'host-ipc'))
        if fs_group == 0:
            findings.append(_make(pod, None, 'root-fsgroup'))
        containers = list(pod.spec.containers or []) + list(pod.spec.init_containers or [])
        for c in containers:
            sc = c.security_context or client.V1SecurityContext()
            privileged = getattr(sc, 'privileged', False) or False
            if privileged:
                findings.append(_make(pod, c, 'privileged'))
            ape = getattr(sc, 'allow_privilege_escalation', None)
            if ape is True:
                findings.append(_make(pod, c, 'allow-priv-escalation'))
            run_as_user = getattr(sc, 'run_as_user', None)
            run_as_non_root = getattr(sc, 'run_as_non_root', None)
            if run_as_user == 0 and run_as_non_root is not True:
                findings.append(_make(pod, c, 'root-user'))
            if run_as_non_root is not True:
                findings.append(_make(pod, c, 'missing-run-as-non-root'))
            run_as_group = getattr(sc, 'run_as_group', None)
            if run_as_group == 0:
                findings.append(_make(pod, c, 'root-group'))
            ro_rootfs = getattr(sc, 'read_only_root_filesystem', None)
            if ro_rootfs is False or ro_rootfs is None:
                findings.append(_make(pod, c, 'writable-rootfs'))
            # seccomp: container override or pod-level
            seccomp = getattr(sc, 'seccomp_profile', None) or secc_profile_pod
            if not seccomp or not getattr(seccomp, 'type', None) or getattr(seccomp, 'type') not in {'RuntimeDefault', 'Localhost'}:
                findings.append(_make(pod, c, 'seccomp-unset'))
            # capabilities
            caps = getattr(sc, 'capabilities', None)
            if caps and getattr(caps, 'add', None):
                for cap in caps.add:
                    if cap not in TOLERATED_CAPS:
                        findings.append(_make(pod, c, 'extra-cap', extra={'cap': cap}))
            # apparmor annotation check
            anns = pod.metadata.annotations or {}
            aa_key = f"container.apparmor.security.beta.kubernetes.io/{c.name}"
            if aa_key in anns and anns[aa_key].lower() == 'unconfined':
                findings.append(_make(pod, c, 'apparmor-unconfined'))
    # Filter restricted-only if requested
    if restricted_only:
        findings = [f for f in findings if classify(f['reason']) == 'restricted']
    # Remove duplicates (pod/ctr/reason combos) keeping first
    seen = set()
    dedup = []
    for f in findings:
        key = (f['namespace'], f['pod'], f.get('container'), f['reason'], f.get('extra', {}).get('cap'))
        if key in seen:
            continue
        seen.add(key)
        dedup.append(f)
    return dedup


def _make(pod, container, reason: str, extra: Dict[str, Any] | None = None) -> Finding:
    return {
        'namespace': pod.metadata.namespace,
        'pod': pod.metadata.name,
        'container': container.name if container else None,
        'reason': reason,
        'severity': classify(reason),
        'extra': extra or {}
    }


def print_human(findings: List[Finding]):
    if not findings:
        print('No pod security standard violations found.')
        return
    print('# Pod Security Findings')
    for f in findings:
        ctr = f['container'] or '*pod*'
        extra = ''
        if f['extra']:
            kv = ','.join(f"{k}={v}" for k, v in f['extra'].items())
            extra = f" ({kv})"
        print(f"{f['namespace']}/{f['pod']}[{ctr}] {f['reason']} [{f['severity']}]" + extra)
    # Simple summary
    counts = {}
    for f in findings:
        counts[f['reason']] = counts.get(f['reason'], 0) + 1
    print('\nSummary:')
    for r, c in sorted(counts.items(), key=lambda x: (-x[1], x[0])):
        print(f"  {r}: {c}")


def main():
    args = parse_args()
    try:
        load_kube()
        v1 = client.CoreV1Api()
        if args.namespace:
            pods = v1.list_namespaced_pod(args.namespace).items
        else:
            pods = v1.list_pod_for_all_namespaces().items
        findings = collect_findings(pods, args.restricted_only, args.include_system)
        if args.json:
            print(json.dumps({'findings': findings, 'count': len(findings)}, indent=2))
            return
        print_human(findings)
    except ApiException as e:
        print(f"API Error: {e}")
        exit(1)
    except Exception as e:
        print(f"Error: {e}")
        exit(1)


if __name__ == '__main__':
    main()
