from kubernetes import client, config

REQUIRED_LABELS = ["owner", "environment"]

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    for ns in v1.list_namespace().items:
        missing = [l for l in REQUIRED_LABELS if l not in ns.metadata.labels]
        if missing:
            print(f"Namespace {ns.metadata.name} missing labels: {missing}")

if __name__ == "__main__":
    main()