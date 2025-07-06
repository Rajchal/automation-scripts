import socket
import ssl
from datetime import datetime

DOMAINS = ['example.com', 'github.com']
EXPIRY_THRESHOLD_DAYS = 10

def check_ssl_expiry(hostname):
    context = ssl.create_default_context()
    with socket.create_connection((hostname, 443)) as sock:
        with context.wrap_socket(sock, server_hostname=hostname) as ssock:
            cert = ssock.getpeercert()
            not_after = datetime.strptime(cert['notAfter'], "%b %d %H:%M:%S %Y %Z")
            days_left = (not_after - datetime.utcnow()).days
            if days_left < 0:
                print(f"EXPIRED: {hostname} expired {-days_left} days ago")
            elif days_left < EXPIRY_THRESHOLD_DAYS:
                print(f"WARNING: {hostname} expires in {days_left} days")

if __name__ == "__main__":
    for d in DOMAINS:
        check_ssl_expiry(d)
