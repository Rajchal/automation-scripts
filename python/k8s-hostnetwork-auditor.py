from kubernetes import client, config

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    for pod in v1.list_pod_for_all_namespaces().items:
        if pod.spec.host_network:
            print(f"Pod {pod.metadata.namespace}/{pod.metadata.name} uses hostNetwork")

if __name__ == "__main__":
    main()