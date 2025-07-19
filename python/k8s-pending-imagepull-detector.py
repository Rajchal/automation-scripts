from kubernetes import client, config

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    pods = v1.list_pod_for_all_namespaces().items
    for pod in pods:
        if pod.status.phase == "Pending":
            for cs in pod.status.container_statuses or []:
                if cs.state.waiting and "ImagePull" in cs.state.waiting.reason:
                    print(f"{pod.metadata.namespace}/{pod.metadata.name} - ImagePull issue: {cs.state.waiting.message}")

if __name__ == "__main__":
    main()