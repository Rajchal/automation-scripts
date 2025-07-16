import subprocess
import datetime

THRESHOLD_DAYS = 180

def main():
    out = subprocess.check_output(['lastlog']).decode().splitlines()
    today = datetime.datetime.now()
    for line in out[1:]:
        parts = line.split()
        if 'Never' in line:
            print(f"User {parts[0]} has never logged in.")
        elif len(parts) > 4:
            try:
                last = ' '.join(parts[2:7])
                last_date = datetime.datetime.strptime(last, "%a %b %d %H:%M:%S %Y")
                if (today - last_date).days > THRESHOLD_DAYS:
                    print(f"User {parts[0]} last logged in {today - last_date} days ago.")
            except Exception:
                continue

if __name__ == "__main__":
    main()