import boto3
from datetime import datetime, timezone, timedelta

THRESHOLD_DAYS = 90
iam = boto3.client('iam')

def main():
    users = iam.list_users()['Users']
    now = datetime.now(timezone.utc)
    for user in users:
        keys = iam.list_access_keys(UserName=user['UserName'])['AccessKeyMetadata']
        for key in keys:
            created = key['CreateDate']
            age = (now - created).days
            if age > THRESHOLD_DAYS:
                print(f"User {user['UserName']} has access key {key['AccessKeyId']} older than {THRESHOLD_DAYS} days ({age} days)")

if __name__ == "__main__":
    main()