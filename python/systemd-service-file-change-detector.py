import hashlib
import os
import json

SERVICE_DIR = "/etc/systemd/system"
HASH_FILE = "/var/tmp/systemd_service_hashes.json"

def hash_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        while chunk := f.read(8192):
            h.update(chunk)
    return h.hexdigest()

def load_hashes():
    if not os.path.exists(HASH_FILE):
        return {}
    with open(HASH_FILE) as f:
        return json.load(f)

def save_hashes(hashes):
    with open(HASH_FILE, 'w') as f:
        json.dump(hashes, f)

def main():
    old = load_hashes()
    new = {}
    for fname in os.listdir(SERVICE_DIR):
        if fname.endswith(".service"):
            path = os.path.join(SERVICE_DIR, fname)
            new[fname] = hash_file(path)
            if fname in old and old[fname] != new[fname]:
                print(f"Service file {fname} has changed!")
    save_hashes(new)

if __name__ == "__main__":
    main()
