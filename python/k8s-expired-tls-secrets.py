from kubernetes import client, config
from cryptography import x509
from cryptography.hazmat.backends import default_backend
import base64
from datetime import datetime, timedelta

WARN_DAYS = 14

def main():
    config.load_kube_config()
    v1 = client.CoreV1Api()
    for ns in [n.metadata.name for n in v1.list_namespace().items]:
        secrets = v1.list_namespaced_secret(ns).items
        for s in secrets:
            if s.type == 'kubernetes.io/tls':
                crt = base64.b64decode(s.data['tls.crt'])
                cert = x509.load_pem_x509_certificate(crt, default_backend())
                days_left = (cert.not_valid_after - datetime.utcnow()).days
                if days_left < 0:
                    print(f"EXPIRED: {ns}/{s.metadata.name} expired {abs(days_left)} days ago")
                elif days_left < WARN_DAYS:
                    print(f"WARNING: {ns}/{s.metadata.name} expires in {days_left} days")

if __name__ == "__main__":
    main()
