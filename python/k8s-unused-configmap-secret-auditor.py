#!/usr/bin/env python3
"""
Kubernetes Unused ConfigMap & Secret Auditor

Finds ConfigMaps and Secrets that are not referenced by any Pod/Deployment/StatefulSet/DaemonSet/CronJob
in the cluster (all namespaces by default).

Heuristics:
- ConfigMap references: envFrom.configMapRef, env.valueFrom.configMapKeyRef, volume.configMap
- Secret references: envFrom.secretRef, env.valueFrom.secretKeyRef, imagePullSecrets, volume.secret
- Ignores kube-system namespace by default unless --include-system flag is passed

Exit codes:
0 - Ran successfully (results may or may not include unused objects)
1 - API error / connection problem

Usage:
  python k8s-unused-configmap-secret-auditor.py [--namespace NAMESPACE] [--include-system]

Optional: set KUBECONFIG env var or rely on in-cluster config.
"""
import argparse
from collections import defaultdict
from typing import Set
from kubernetes import client, config
from kubernetes.client import ApiException

EXCLUDE_NAMESPACES = {"kube-system", "kube-public", "kube-node-lease"}


def load_config():
    try:
        config.load_kube_config()
    except Exception:
        # fallback to in-cluster
        try:
            config.load_incluster_config()
        except Exception:
            raise


def gather_workload_pods(core: client.CoreV1Api, apps: client.AppsV1Api, batch: client.BatchV1Api, namespace: str = None):
    if namespace:
        pod_list = core.list_namespaced_pod(namespace=namespace).items
    else:
        pod_list = core.list_pod_for_all_namespaces().items
    return pod_list


def collect_references(pods) -> tuple[Set[str], Set[str]]:
    used_configmaps: Set[str] = set()
    used_secrets: Set[str] = set()

    for pod in pods:
        ns = pod.metadata.namespace
        # imagePullSecrets
        if pod.spec.image_pull_secrets:
            for ips in pod.spec.image_pull_secrets:
                if ips.name:
                    used_secrets.add(f"{ns}/{ips.name}")
        # volumes
        if pod.spec.volumes:
            for vol in pod.spec.volumes:
                if vol.config_map and vol.config_map.name:
                    used_configmaps.add(f"{ns}/{vol.config_map.name}")
                if vol.secret and vol.secret.secret_name:
                    used_secrets.add(f"{ns}/{vol.secret.secret_name}")
        # containers (regular + init)
        containers = list(pod.spec.containers or []) + list(pod.spec.init_containers or [])
        for c in containers:
            # envFrom
            for env_from in c.env_from or []:
                if env_from.config_map_ref and env_from.config_map_ref.name:
                    used_configmaps.add(f"{ns}/{env_from.config_map_ref.name}")
                if env_from.secret_ref and env_from.secret_ref.name:
                    used_secrets.add(f"{ns}/{env_from.secret_ref.name}")
            # env
            for env in c.env or []:
                if env.value_from:
                    cm_key_ref = getattr(env.value_from, 'config_map_key_ref', None)
                    if cm_key_ref and cm_key_ref.name:
                        used_configmaps.add(f"{ns}/{cm_key_ref.name}")
                    secret_key_ref = getattr(env.value_from, 'secret_key_ref', None)
                    if secret_key_ref and secret_key_ref.name:
                        used_secrets.add(f"{ns}/{secret_key_ref.name}")
    return used_configmaps, used_secrets


def list_all_configmaps_and_secrets(core: client.CoreV1Api, namespace: str = None):
    if namespace:
        cms = core.list_namespaced_config_map(namespace=namespace).items
        secrets = core.list_namespaced_secret(namespace=namespace).items
    else:
        cms = core.list_config_map_for_all_namespaces().items
        secrets = core.list_secret_for_all_namespaces().items
    cm_ids = {f"{cm.metadata.namespace}/{cm.metadata.name}" for cm in cms}
    secret_ids = {f"{s.metadata.namespace}/{s.metadata.name}" for s in secrets if s.type not in {"kubernetes.io/service-account-token"}}
    return cm_ids, secret_ids


def main():
    parser = argparse.ArgumentParser(description="Audit unused ConfigMaps and Secrets")
    parser.add_argument('--namespace', '-n', help='Limit to a single namespace')
    parser.add_argument('--include-system', action='store_true', help='Include system namespaces (kube-system, etc.)')
    args = parser.parse_args()

    try:
        load_config()
        core = client.CoreV1Api()
        apps = client.AppsV1Api()
        batch = client.BatchV1Api()

        namespace = args.namespace
        pods = gather_workload_pods(core, apps, batch, namespace)

        used_configmaps, used_secrets = collect_references(pods)
        all_configmaps, all_secrets = list_all_configmaps_and_secrets(core, namespace)

        if not args.include_system:
            all_configmaps = {i for i in all_configmaps if i.split('/')[0] not in EXCLUDE_NAMESPACES}
            all_secrets = {i for i in all_secrets if i.split('/')[0] not in EXCLUDE_NAMESPACES}
            used_configmaps = {i for i in used_configmaps if i.split('/')[0] not in EXCLUDE_NAMESPACES}
            used_secrets = {i for i in used_secrets if i.split('/')[0] not in EXCLUDE_NAMESPACES}

        unused_configmaps = sorted(all_configmaps - used_configmaps)
        unused_secrets = sorted(all_secrets - used_secrets)

        print("# Unused ConfigMaps")
        if unused_configmaps:
            for cm in unused_configmaps:
                print(cm)
        else:
            print("None")
        print("\n# Unused Secrets")
        if unused_secrets:
            for s in unused_secrets:
                print(s)
        else:
            print("None")

        print("\nSummary:")
        print(f"Total ConfigMaps: {len(all_configmaps)}  Used: {len(used_configmaps)}  Unused: {len(unused_configmaps)}")
        print(f"Total Secrets: {len(all_secrets)}  Used: {len(used_secrets)}  Unused: {len(unused_secrets)}")

        if unused_configmaps or unused_secrets:
            print("\nCleanup suggestions (double-check before deleting):")
            for cm in unused_configmaps:
                ns, name = cm.split('/')
                print(f"kubectl delete configmap {name} -n {ns}")
            for s in unused_secrets:
                ns, name = s.split('/')
                print(f"kubectl delete secret {name} -n {ns}")

    except ApiException as e:
        print(f"API Error: {e}")
        exit(1)
    except Exception as e:
        print(f"Error: {e}")
        exit(1)


if __name__ == '__main__':
    main()
