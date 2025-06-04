import ssl
import socket
from datetime import datetime

# Check a list of hosts for expired SSL certificates

def check_cert(host, port=443):
    ctx = ssl.create_default_context()
    with socket.create_connection((host, port)) as sock:
        with ctx.wrap_socket(sock, server_hostname=host) as ssock:
            cert = ssock.getpeercert()
            expires = datetime.strptime(cert['notAfter'], "%b %d %H:%M:%S %Y %Z")
            days = (expires - datetime.utcnow()).days
            if days < 0:
                print(f"{host}: EXPIRED ({-days} days ago)")
            elif days < 30:
                print(f"{host}: Expiring soon ({days} days left)")
            else:
                print(f"{host}: Valid ({days} days left)")

if __name__ == "__main__":
    hosts = ["example.com", "expired.badssl.com"]
    for h in hosts:
        try:
            check_cert(h)
        except Exception as e:
            print(f"{h}: Error - {e}")
