import hashlib
import os
import json

CRITICAL_FILES = ["/etc/passwd", "/etc/shadow"]
HASH_FILE = "/var/tmp/file_hashes.json"

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
    old_hashes = load_hashes()
    new_hashes = {}
    for file in CRITICAL_FILES:
        if not os.path.exists(file):
            continue
        new_hash = hash_file(file)
        new_hashes[file] = new_hash
        if file in old_hashes and old_hashes[file] != new_hash:
            print(f"WARNING: {file} has changed since last scan!")
    save_hashes(new_hashes)

if __name__ == "__main__":
    main()
