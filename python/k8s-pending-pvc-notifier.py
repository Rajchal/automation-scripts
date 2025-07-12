from kubernetes import client, config
from datetime import datetime, timezone, timedelta

THRESHOLD_MINUTES = 30

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    now = datetime.now(timezone.utc)
    pvcs = v1.list_persistent_volume_claim_for_all_namespaces().items
    for pvc in pvcs:
        if pvc.status.phase == "Pending" and pvc.metadata.creation_timestamp:
            age = (now - pvc.metadata.creation_timestamp).total_seconds() / 60
            if age > THRESHOLD_MINUTES:
                print(f"PVC {pvc.metadata.namespace}/{pvc.metadata.name} pending for {int(age)} minutes")

if __name__ == "__main__":
    main()
