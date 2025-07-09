import subprocess

def main():
    out = subprocess.check_output(['docker', 'ps', '-q']).decode().splitlines()
    for cid in out:
        exec_out = subprocess.check_output(['docker', 'exec', cid, 'ps', 'axo', 'stat,pid,cmd']).decode()
        for l in exec_out.splitlines():
            if l.startswith('Z'):
                print(f"Zombie process in container {cid}: {l}")

if __name__ == "__main__":
    main()
