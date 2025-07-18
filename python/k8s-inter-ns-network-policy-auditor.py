from kubernetes import client, config

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    net_api = client.NetworkingV1Api()
    ns_with_policy = set()
    for np in net_api.list_network_policy_for_all_namespaces().items:
        if np.spec.pod_selector and np.spec.ingress:
            ns_with_policy.add(np.metadata.namespace)
    for ns in v1.list_namespace().items:
        if ns.metadata.name not in ns_with_policy:
            print(f"Namespace {ns.metadata.name} has no restrictive inter-namespace network policy.")

if __name__ == "__main__":
    main()