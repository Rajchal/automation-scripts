from kubernetes import client, config
import os

LOG_DIR = "./crashloop_logs"

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    if not os.path.exists(LOG_DIR):
        os.makedirs(LOG_DIR)
    pods = v1.list_pod_for_all_namespaces().items
    for pod in pods:
        for c in pod.status.container_statuses or []:
            if c.state.waiting and c.state.waiting.reason == "CrashLoopBackOff":
                ns = pod.metadata.namespace
                name = pod.metadata.name
                log = v1.read_namespaced_pod_log(name, ns)
                with open(f"{LOG_DIR}/{ns}_{name}.log", "w") as f:
                    f.write(log)
                print(f"Collected logs for {ns}/{name}")

if __name__ == "__main__":
    main()
