from kubernetes import client, config

THRESHOLD = 0.9  # 90%

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    quotas = v1.list_resource_quota_for_all_namespaces().items
    for quota in quotas:
        for res, used in quota.status.used.items():
            hard = quota.status.hard[res]
            try:
                used_val = int(used)
                hard_val = int(hard)
                if used_val / hard_val > THRESHOLD:
                    print(f"Quota almost exhausted in {quota.metadata.namespace}: {res} ({used}/{hard})")
            except Exception:
                continue

if __name__ == "__main__":
    main()
