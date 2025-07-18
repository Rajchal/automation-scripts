from kubernetes import client, config
import re

PATTERNS = [re.compile(r'key', re.I), re.compile(r'token', re.I), re.compile(r'pass', re.I)]

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    for pod in v1.list_pod_for_all_namespaces().items:
        for container in pod.spec.containers:
            for env in container.env or []:
                if any(p.search(env.name) for p in PATTERNS):
                    print(f"Pod {pod.metadata.namespace}/{pod.metadata.name} container {container.name} has suspicious env var: {env.name}")

if __name__ == "__main__":
    main()