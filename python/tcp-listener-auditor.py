import subprocess
import re

def main():
    output = subprocess.check_output(['ss', '-tulnp']).decode()
    for line in output.splitlines():
        if 'LISTEN' in line and '0.0.0.0:' in line:
            match = re.search(r'0\.0\.0\.0:(\d+).*users:\(\("([^"]+)",', line)
            if match:
                port, program = match.groups()
                print(f"{program} listening on all interfaces port {port}")

if __name__ == "__main__":
    main()