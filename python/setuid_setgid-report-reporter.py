import os

PATHS = ["/usr", "/bin", "/sbin", "/home"]

def main():
    for root_path in PATHS:
        for root, dirs, files in os.walk(root_path):
            for fname in files:
                try:
                    path = os.path.join(root, fname)
                    mode = os.stat(path).st_mode
                    if mode & 0o4000:
                        print(f"Setuid: {path}")
                    if mode & 0o2000:
                        print(f"Setgid: {path}")
                except Exception:
                    continue

if __name__ == "__main__":
    main()
