from kubernetes import client, config

STANDARD_TYPES = {"Opaque", "kubernetes.io/tls", "kubernetes.io/service-account-token"}

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    secrets = v1.list_secret_for_all_namespaces().items
    for secret in secrets:
        if secret.type not in STANDARD_TYPES:
            print(f"{secret.metadata.namespace}/{secret.metadata.name} has non-standard type: {secret.type}")

if __name__ == "__main__":
    main()