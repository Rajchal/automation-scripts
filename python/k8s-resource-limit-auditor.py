from kubernetes import client, config

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    pods = v1.list_pod_for_all_namespaces().items
    for pod in pods:
        for container in pod.spec.containers:
            r = container.resources
            if not (r.requests and r.limits):
                print(f"{pod.metadata.namespace}/{pod.metadata.name}/{container.name} missing resource requests/limits")

if __name__ == "__main__":
    main()
