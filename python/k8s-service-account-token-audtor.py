from kubernetes import client, config

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    for ns in v1.list_namespace().items:
        sa_list = v1.list_namespaced_service_account(ns.metadata.name).items
        for sa in sa_list:
            if sa.automount_service_account_token is not False:
                print(f"ServiceAccount {ns.metadata.name}/{sa.metadata.name} has automount_service_account_token enabled")

if __name__ == "__main__":
    main()