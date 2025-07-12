import os

PATHS = ["/etc", "/var", "/home"]

def main():
    for root_path in PATHS:
        for root, dirs, files in os.walk(root_path):
            for fname in files:
                try:
                    path = os.path.join(root, fname)
                    if os.stat(path).st_mode & 0o002:
                        print(f"World-writable file: {path}")
                except Exception:
                    continue

if __name__ == "__main__":
    main()
