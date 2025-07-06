from kubernetes import client, config
from datetime import datetime, timezone, timedelta

THRESHOLD_DAYS = 7

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    pods = v1.list_pod_for_all_namespaces().items
    now = datetime.now(timezone.utc)
    for pod in pods:
        start_time = pod.status.start_time
        if start_time and (now - start_time).days > THRESHOLD_DAYS:
            print(f"Pod {pod.metadata.namespace}/{pod.metadata.name} running for {(now-start_time).days} days")

if __name__ == "__main__":
    main()
