from kubernetes import client, config
from datetime import datetime, timezone, timedelta

def main():
    config.load_kube_config()
    batch = client.BatchV1Api()
    now = datetime.now(timezone.utc)
    since = now - timedelta(days=1)
    jobs = batch.list_job_for_all_namespaces().items
    for job in jobs:
        ct = job.status.completion_time
        if ct and ct < since:
            continue
        failed = job.status.failed or 0
        succeeded = job.status.succeeded or 0
        if failed > succeeded:
            print(f"{job.metadata.namespace}/{job.metadata.name}: {failed} failed, {succeeded} succeeded")

if __name__ == "__main__":
    main()
