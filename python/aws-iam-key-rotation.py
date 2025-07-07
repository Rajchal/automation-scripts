import boto3
import datetime

THRESHOLD_DAYS = 90
iam = boto3.client('iam')

def main():
    users = iam.list_users()['Users']
    for user in users:
        keys = iam.list_access_keys(UserName=user['UserName'])['AccessKeyMetadata']
        for key in keys:
            age = (datetime.datetime.now(datetime.timezone.utc) - key['CreateDate']).days
            if age > THRESHOLD_DAYS:
                print(f"User {user['UserName']} has key {key['AccessKeyId']} older than {THRESHOLD_DAYS} days ({age} days old)")

if __name__ == "__main__":
    main()
