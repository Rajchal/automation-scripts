import subprocess
import datetime

SERVICES = ['nginx', 'docker', 'sshd']
LOG_PATH = '/var/log/self_heal.log'

def is_active(service):
    result = subprocess.run(['systemctl', 'is-active', service], stdout=subprocess.PIPE)
    return result.stdout.decode().strip() == 'active'

def restart_service(service):
    subprocess.run(['systemctl', 'restart', service])

def log_event(service):
    with open(LOG_PATH, 'a') as f:
        f.write(f"{datetime.datetime.now()} - Restarted {service}\n")

def main():
    for svc in SERVICES:
        if not is_active(svc):
            restart_service(svc)
            log_event(svc)

if __name__ == '__main__':
    main()
