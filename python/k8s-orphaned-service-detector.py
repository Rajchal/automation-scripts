from kubernetes import client, config

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    services = v1.list_service_for_all_namespaces().items
    endpoints = v1.list_endpoints_for_all_namespaces().items
    svc_map = {(s.metadata.namespace, s.metadata.name): False for s in services}
    for ep in endpoints:
        if ep.subsets:
            key = (ep.metadata.namespace, ep.metadata.name)
            svc_map[key] = True
    for (ns, name), has_ep in svc_map.items():
        if not has_ep:
            print(f"Orphaned Service: {ns}/{name}")

if __name__ == "__main__":
    main()
