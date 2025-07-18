import boto3
from datetime import datetime, timezone, timedelta
import csv

THRESHOLD_DAYS = 30
iam = boto3.client('iam')

def main():
    report = iam.get_credential_report()['Content'].decode()
    reader = csv.DictReader(report.splitlines())
    now = datetime.now(timezone.utc)
    for row in reader:
        pwd_date = row.get('password_last_changed')
        if pwd_date and pwd_date != 'N/A':
            changed = datetime.strptime(pwd_date, "%Y-%m-%dT%H:%M:%S+00:00")
            age = (now - changed).days
            if age > THRESHOLD_DAYS:
                print(f"User {row['user']} password last changed {age} days ago.")

if __name__ == "__main__":
    main()