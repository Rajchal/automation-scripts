import subprocess
import time

def main():
    host_time = int(time.time())
    cids = subprocess.check_output(['docker', 'ps', '-q']).decode().splitlines()
    for cid in cids:
        try:
            container_time = int(subprocess.check_output([
                'docker', 'exec', cid, 'date', '+%s'
            ]).decode().strip())
            skew = abs(host_time - container_time)
            if skew > 5:
                print(f"Container {cid} time skew: {skew} seconds")
        except Exception:
            continue

if __name__ == "__main__":
    main()
