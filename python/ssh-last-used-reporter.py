import subprocess

def main():
    out = subprocess.check_output(['lastlog', '-u', '0-99999']).decode()
    for line in out.splitlines()[1:]:  # Skip header
        parts = line.split()
        if 'Never' in line:
            print(f"User {parts[0]} has never logged in.")
        else:
            print(f"User {parts[0]} last logged in: {' '.join(parts[2:])}")

if __name__ == "__main__":
    main()
