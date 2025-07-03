import os
import time
import subprocess

CERT_PATH = "/etc/letsencrypt/live/example.com/fullchain.pem"
CHECK_INTERVAL = 60  # seconds

def get_mtime(path):
    return os.path.getmtime(path)

def reload_nginx():
    subprocess.run(["systemctl", "reload", "nginx"])

def main():
    last_mtime = get_mtime(CERT_PATH)
    while True:
        time.sleep(CHECK_INTERVAL)
        mtime = get_mtime(CERT_PATH)
        if mtime != last_mtime:
            print("Certificate updated, reloading Nginx...")
            reload_nginx()
            last_mtime = mtime

if __name__ == "__main__":
    main()
