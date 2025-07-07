import subprocess

EXPECTED = ['nginx', 'postgres', 'redis']

def main():
    running = subprocess.check_output(['ps', '-eo', 'comm']).decode().splitlines()
    for svc in EXPECTED:
        if svc in running:
            status = subprocess.run(['systemctl', 'is-active', svc], stdout=subprocess.PIPE)
            if status.stdout.decode().strip() != 'active':
                print(f"Process '{svc}' running but not tracked by systemd!")

if __name__ == "__main__":
    main()
