import os
import datetime

MOUNT_PATHS = ['/mnt', '/media']
STALE_DAYS = 30

def main():
    now = datetime.datetime.now()
    for path in MOUNT_PATHS:
        if os.path.exists(path):
            for root, dirs, files in os.walk(path):
                for fname in dirs + files:
                    fpath = os.path.join(root, fname)
                    try:
                        atime = datetime.datetime.fromtimestamp(os.stat(fpath).st_atime)
                        if (now - atime).days > STALE_DAYS:
                            print(f"Stale mount file: {fpath} (last accessed {(now - atime).days} days ago)")
                    except Exception:
                        continue

if __name__ == "__main__":
    main()