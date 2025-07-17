from kubernetes import client, config
from datetime import datetime, timezone, timedelta

RESTART_THRESHOLD = 5

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    pods = v1.list_pod_for_all_namespaces().items
    for pod in pods:
        for cs in pod.status.container_statuses or []:
            if cs.restart_count > RESTART_THRESHOLD:
                print(f"{pod.metadata.namespace}/{pod.metadata.name}/{cs.name} restarted {cs.restart_count} times")

if __name__ == "__main__":
    main()