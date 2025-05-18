import subprocess

def find_large_files(size_mb=10):
    print(f"Searching for files > {size_mb}MB in Git history...")
    out = subprocess.check_output([
        "git", "rev-list", "--objects", "--all"
    ]).decode().splitlines()
    for line in out:
        parts = line.strip().split()
        if len(parts) == 2:
            file_hash, filename = parts
            try:
                size = int(subprocess.check_output([
                    "git", "cat-file", "-s", file_hash
                ]).strip())
                if size > size_mb * 1024 * 1024:
                    print(f"{filename}: {size / (1024*1024):.2f} MB")
            except Exception:
                continue

if __name__ == "__main__":
    find_large_files(10)
