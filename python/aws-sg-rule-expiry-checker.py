import boto3
import re
import datetime

ec2 = boto3.client('ec2')

def main():
    sgs = ec2.describe_security_groups()['SecurityGroups']
    today = datetime.date.today()
    for sg in sgs:
        for rule in sg.get('IpPermissions', []):
            for desc in rule.get('IpRanges', []):
                comment = desc.get('Description', '')
                match = re.search(r'expires:(\d{4}-\d{2}-\d{2})', comment)
                if match:
                    expiry = datetime.datetime.strptime(match.group(1), "%Y-%m-%d").date()
                    if expiry < today:
                        print(f"SG {sg['GroupId']} rule {comment} expired on {expiry}")

if __name__ == "__main__":
    main()