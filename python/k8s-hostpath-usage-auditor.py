from kubernetes import client, config

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    pods = v1.list_pod_for_all_namespaces().items
    for pod in pods:
        for vol in pod.spec.volumes or []:
            if vol.host_path:
                print(f"Pod {pod.metadata.namespace}/{pod.metadata.name} uses HostPath: {vol.host_path.path}")

if __name__ == "__main__":
    main()