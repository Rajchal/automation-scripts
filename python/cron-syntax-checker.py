import subprocess
import pwd

def main():
    for user in pwd.getpwall():
        try:
            output = subprocess.check_output(['crontab', '-u', user.pw_name, '-l'], stderr=subprocess.STDOUT)
            for line in output.decode().splitlines():
                if line.strip() and not line.startswith('#'):
                    # Simple check: should have at least 5 fields before command
                    if len(line.split()) < 6:
                        print(f"Invalid cron syntax for user {user.pw_name}: {line}")
        except subprocess.CalledProcessError:
            continue

if __name__ == "__main__":
    main()