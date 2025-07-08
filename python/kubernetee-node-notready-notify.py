from kubernetes import client, config

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    nodes = v1.list_node().items
    for node in nodes:
        for cond in node.status.conditions:
            if cond.type == "Ready" and cond.status != "True":
                print(f"Node {node.metadata.name} is NotReady!")

if __name__ == "__main__":
    main()
