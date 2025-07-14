from kubernetes import client, config

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    for svc in v1.list_service_for_all_namespaces().items:
        if svc.spec.type in ("LoadBalancer", "NodePort"):
            ips = svc.status.load_balancer.ingress or []
            ext_ips = [ip.ip or ip.hostname for ip in ips]
            if ext_ips:
                print(f"{svc.metadata.namespace}/{svc.metadata.name} type={svc.spec.type} external IP(s): {', '.join(ext_ips)}")

if __name__ == "__main__":
    main()