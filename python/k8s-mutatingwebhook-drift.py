from kubernetes import client, config
import yaml

DESIRED_PATH = "desired_webhook.yaml"

def main():
    config.load_kube_config()
    api = client.AdmissionregistrationV1Api()
    with open(DESIRED_PATH) as f:
        desired = yaml.safe_load(f)
    curr = api.list_mutating_webhook_configuration().items
    for conf in curr:
        name = conf.metadata.name
        for d in desired.get("items", []):
            if d["metadata"]["name"] == name and d != conf.to_dict():
                print(f"Webhook {name} drift detected.")

if __name__ == "__main__":
    main()
