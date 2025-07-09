from kubernetes import client, config

THRESHOLD = 0.8

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    v1r = client.CustomObjectsApi()
    pvcs = v1.list_persistent_volume_claim_for_all_namespaces().items
    for pvc in pvcs:
        ns = pvc.metadata.namespace
        name = pvc.metadata.name
        try:
            usage = v1r.get_namespaced_custom_object(
                group="metrics.k8s.io",
                version="v1beta1",
                namespace=ns,
                plural="pods",
                name=name)
            # This is a placeholder; adapt to your cluster's metric sources.
            used = float(usage['status']['usedBytes'])
            total = float(usage['status']['capacityBytes'])
            if used / total > THRESHOLD:
                print(f"PVC {ns}/{name}: {(used/total)*100:.1f}% used")
        except Exception:
            continue

if __name__ == "__main__":
    main()
