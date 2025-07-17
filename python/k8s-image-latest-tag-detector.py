from kubernetes import client, config

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    pods = v1.list_pod_for_all_namespaces().items
    for pod in pods:
        for container in pod.spec.containers:
            if container.image.endswith(':latest'):
                print(f"Pod {pod.metadata.namespace}/{pod.metadata.name} uses :latest image ({container.image})")

if __name__ == "__main__":
    main()