from kubernetes import client, config

DEPRECATED_APIS = ['extensions/v1beta1', 'apps/v1beta1']

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    batch = client.BatchV1Api()
    for pod in v1.list_pod_for_all_namespaces().items:
        api_version = getattr(pod, 'api_version', None)
        if api_version in DEPRECATED_APIS:
            print(f"Pod {pod.metadata.namespace}/{pod.metadata.name} uses deprecated API {api_version}")

if __name__ == "__main__":
    main()