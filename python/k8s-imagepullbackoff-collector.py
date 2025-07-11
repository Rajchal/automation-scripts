from kubernetes import client, config

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    pods = v1.list_pod_for_all_namespaces().items
    for pod in pods:
        for status in pod.status.container_statuses or []:
            state = status.state
            if state.waiting and state.waiting.reason == "ImagePullBackOff":
                print(f"Namespace: {pod.metadata.namespace}, Pod: {pod.metadata.name}, Image: {status.image}, Tag: {status.image_id}")

if __name__ == "__main__":
    main()
