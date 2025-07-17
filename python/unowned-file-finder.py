import os
import pwd
import grp

PATHS = ["/var", "/home", "/etc"]

def main():
    for root_path in PATHS:
        for root, dirs, files in os.walk(root_path):
            for fname in files:
                path = os.path.join(root, fname)
                try:
                    stat = os.stat(path)
                    try:
                        pwd.getpwuid(stat.st_uid)
                    except KeyError:
                        print(f"Unowned file: {path} (uid: {stat.st_uid})")
                    try:
                        grp.getgrgid(stat.st_gid)
                    except KeyError:
                        print(f"Unowned group: {path} (gid: {stat.st_gid})")
                except Exception:
                    continue

if __name__ == "__main__":
    main()