import subprocess
import json

def main():
    result = subprocess.check_output(['docker', 'stats', '--no-stream', '--format', '{{json .}}'])
    for line in result.decode().splitlines():
        stats = json.loads(line)
        net_io = stats.get('NetIO', '0B / 0B')
        container = stats.get('Name')
        rx, tx = net_io.split(' / ')
        def parse_bytes(s):
            num, unit = float(s[:-1]), s[-1]
            mult = {'B':1, 'k':1024, 'M':1024**2, 'G':1024**3}
            return num * mult.get(unit, 1)
        if parse_bytes(rx) > 1e8 or parse_bytes(tx) > 1e8:  # Over ~100MB
            print(f"High network usage: {container} Rx: {rx}, Tx: {tx}")

if __name__ == "__main__":
    main()
