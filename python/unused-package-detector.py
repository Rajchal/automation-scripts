import subprocess

def main():
    pkgs = set(subprocess.check_output(['dpkg-query', '-W', '-f', '${Package}\n']).decode().splitlines())
    used_pkgs = set()
    for pid in os.listdir('/proc'):
        if pid.isdigit():
            try:
                maps = open(f'/proc/{pid}/maps').read()
                for pkg in pkgs:
                    if pkg in maps:
                        used_pkgs.add(pkg)
            except Exception:
                continue
    unused = pkgs - used_pkgs
    for pkg in unused:
        print(f"Unused package: {pkg}")

if __name__ == "__main__":
    main()