import os
import pwd
import stat

def main():
    for p in pwd.getpwall():
        home = p.pw_dir
        if os.path.isdir(home):
            perms = stat.S_IMODE(os.stat(home).st_mode)
            if perms > 0o750:
                print(f"User {p.pw_name} home directory ({home}) permissions are {oct(perms)}")

if __name__ == "__main__":
    main()