import boto3
from datetime import datetime, timezone, timedelta

THRESHOLD_DAYS = 7
ec2 = boto3.client('ec2')

def main():
    now = datetime.now(timezone.utc)
    resp = ec2.describe_instance_status(IncludeAllInstances=True)
    for inst in resp['InstanceStatuses']:
        for event in inst.get('Events', []):
            not_before = event['NotBefore']
            days = (not_before - now).days
            if days < THRESHOLD_DAYS:
                print(f"Instance {inst['InstanceId']} has event {event['Code']} in {days} days (on {not_before})")

if __name__ == "__main__":
    main()
