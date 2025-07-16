from kubernetes import client, config

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    nodes = v1.list_node().items
    for node in nodes:
        info = node.status.node_info
        print(f"Node {node.metadata.name}: Kernel Version {info.kernel_version}")

if __name__ == "__main__":
    main()