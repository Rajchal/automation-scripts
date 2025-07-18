import os

KEY_PATTERNS = ['id_rsa', '.pem', 'id_dsa', 'id_ecdsa', 'id_ed25519']
SEARCH_PATHS = ['/home', '/etc', '/root']

def main():
    for root_path in SEARCH_PATHS:
        for root, dirs, files in os.walk(root_path):
            for fname in files:
                if any(p in fname for p in KEY_PATTERNS):
                    path = os.path.join(root, fname)
                    try:
                        if os.stat(path).st_mode & 0o004:
                            print(f"World-readable key: {path}")
                    except Exception:
                        continue

if __name__ == "__main__":
    main()