from kubernetes import client, config

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    pods = v1.list_pod_for_all_namespaces().items

    deploy_node_map = {}
    for pod in pods:
        labels = pod.metadata.labels or {}
        deploy = labels.get('app') or labels.get('deployment')
        node = pod.spec.node_name
        if deploy and node:
            deploy_node_map.setdefault(deploy, []).append(node)

    for deploy, nodes in deploy_node_map.items():
        node_counts = {n: nodes.count(n) for n in set(nodes)}
        for node, count in node_counts.items():
            if count > 1:
                print(f"Warning: Deployment '{deploy}' has {count} pods on node '{node}'.")

if __name__ == '__main__':
    main()
