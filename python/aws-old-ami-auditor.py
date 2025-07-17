import boto3
from datetime import datetime, timezone, timedelta

THRESHOLD_DAYS = 180
ec2 = boto3.client('ec2')

def main():
    now = datetime.now(timezone.utc)
    reservations = ec2.describe_instances()['Reservations']
    for res in reservations:
        for inst in res['Instances']:
            ami = ec2.describe_images(ImageIds=[inst['ImageId']])['Images'][0]
            created = datetime.strptime(ami['CreationDate'], "%Y-%m-%dT%H:%M:%S.%fZ")
            age = (now - created).days
            if age > THRESHOLD_DAYS:
                print(f"Instance {inst['InstanceId']} uses old AMI ({inst['ImageId']}, {age} days old)")

if __name__ == "__main__":
    main()