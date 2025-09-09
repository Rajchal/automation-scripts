#!/usr/bin/env python3
"""
Kubernetes Image Registry Compliance Auditor

Purpose:
  Ensures all running Pods use images from an allowed registry list
  and optionally flags images using the 'latest' tag or missing digest.

Checks:
  - Registry enforcement: image must start with one of allowed prefixes
  - Disallowed 'latest' tag (unless --allow-latest)
  - Missing immutable digest (no @sha256:...) if --require-digest
  - Namespace exemption list (skip namespaces)

Output:
  Human summary or JSON list of non-compliant containers.

Usage:
  python k8s-image-registry-compliance.py --allowed ghcr.io/myorg/,123456789012.dkr.ecr.us-east-1.amazonaws.com/ \
      --exempt kube-system,monitoring --require-digest

  python k8s-image-registry-compliance.py --allowed myprivateregistry.local/ --json

Exit codes:
  0 success (even if violations found)
  1 config/API error
"""
from __future__ import annotations
import argparse
import json
from typing import List, Dict
from kubernetes import client, config
from kubernetes.client import ApiException


def load_config():
    try:
        config.load_kube_config()
    except Exception:
        config.load_incluster_config()


def parse_args():
    p = argparse.ArgumentParser(description="Audit Pod images for registry compliance")
    p.add_argument('--allowed', required=True, help='Comma list of allowed image registry prefixes (e.g. ghcr.io/org/,123.dkr.ecr.region.amazonaws.com/)')
    p.add_argument('--exempt', help='Comma list of namespaces to skip')
    p.add_argument('--allow-latest', action='store_true', help='Do not flag :latest tag usage')
    p.add_argument('--require-digest', action='store_true', help='Flag images missing content digest (@sha256:...)')
    p.add_argument('--json', action='store_true', help='JSON output')
    return p.parse_args()


def image_parts(image: str):
    # Return (name_without_tag_digest, tag, digest)
    digest = None
    if '@' in image:
        image, digest = image.split('@', 1)
    tag = None
    if ':' in image.split('/')[-1]:  # tag separator only in last path component
        base, tag = image.rsplit(':', 1)
        return base, tag, digest
    return image, tag, digest


def audit_pods(v1: client.CoreV1Api, allowed_prefixes: List[str], exempt_ns: List[str], allow_latest: bool, require_digest: bool):
    pods = v1.list_pod_for_all_namespaces().items
    violations = []
    for pod in pods:
        ns = pod.metadata.namespace
        if exempt_ns and ns in exempt_ns:
            continue
        containers = list(pod.spec.containers or []) + list(pod.spec.init_containers or [])
        for c in containers:
            img = c.image
            base, tag, digest = image_parts(img)
            compliant = any(base.startswith(pfx) or img.startswith(pfx) for pfx in allowed_prefixes)
            reasons = []
            if not compliant:
                reasons.append('disallowed-registry')
            if tag is None and not digest:
                # Implicit latest
                if not allow_latest:
                    reasons.append('implicit-latest-tag')
            elif tag == 'latest' and not allow_latest:
                reasons.append('latest-tag')
            if require_digest and not digest:
                reasons.append('missing-digest')
            if reasons:
                violations.append({
                    'namespace': ns,
                    'pod': pod.metadata.name,
                    'container': c.name,
                    'image': img,
                    'reasons': reasons
                })
    return violations


def main():
    args = parse_args()
    allowed = [a.strip() for a in args.allowed.split(',') if a.strip()]
    exempt = [e.strip() for e in args.exempt.split(',')] if args.exempt else []

    try:
        load_config()
        v1 = client.CoreV1Api()
        violations = audit_pods(v1, allowed, exempt, args.allow_latest, args.require_digest)

        if args.json:
            print(json.dumps({'violations': violations, 'count': len(violations)}, indent=2))
            return

        if not violations:
            print('All pod images compliant.')
            return
        print('# Image Registry Compliance Violations')
        for v in violations:
            print(f"{v['namespace']}/{v['pod']} {v['container']} -> {v['image']} ({','.join(v['reasons'])})")
        print('\nSuggested remediation:')
        for v in violations[:10]:
            print(f"  - Update deployment in namespace {v['namespace']} to use allowed registry and immutable digest for {v['image']}")
        if len(violations) > 10:
            print(f"  ... {len(violations)-10} more")
    except ApiException as e:
        print(f"API Error: {e}")
        exit(1)
    except Exception as e:
        print(f"Error: {e}")
        exit(1)


if __name__ == '__main__':
    main()
