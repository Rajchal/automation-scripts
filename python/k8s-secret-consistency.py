from kubernetes import client, config

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    namespaces = [ns.metadata.name for ns in v1.list_namespace().items]
    secret_map = {}
    for ns in namespaces:
        for secret in v1.list_namespaced_secret(ns).items:
            key = secret.metadata.name
            data = secret.data
            if key in secret_map and secret_map[key] != data:
                print(f"Inconsistency for secret '{key}' between namespaces.")
            secret_map[key] = data

if __name__ == "__main__":
    main()
