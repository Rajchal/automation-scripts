from kubernetes import client, config

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    pods = v1.list_pod_for_all_namespaces().items
    for pod in pods:
        spec = pod.spec
        if not (spec.affinity and (spec.affinity.node_affinity or spec.affinity.pod_anti_affinity)):
            print(f"Pod {pod.metadata.namespace}/{pod.metadata.name} missing node affinity/anti-affinity")

if __name__ == "__main__":
    main()