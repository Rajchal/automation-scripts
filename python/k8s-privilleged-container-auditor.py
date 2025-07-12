from kubernetes import client, config

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    pods = v1.list_pod_for_all_namespaces().items
    for pod in pods:
        for container in pod.spec.containers:
            sc = container.security_context
            if sc and getattr(sc, "privileged", False):
                print(f"Privileged container: {pod.metadata.namespace}/{pod.metadata.name}/{container.name}")

if __name__ == "__main__":
    main()
