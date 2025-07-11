import re
import datetime
CRON_PATH = "/etc/crontab"

def main():
    with open(CRON_PATH) as f:
        for line in f:
            match = re.search(r'#\s*end:(\d{4}-\d{2}-\d{2})', line)
            if match:
                end_date = datetime.datetime.strptime(match.group(1), "%Y-%m-%d").date()
                if end_date < datetime.date.today():
                    print(f"Expired cron job: {line.strip()}")

if __name__ == "__main__":
    main()
