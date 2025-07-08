import boto3

ec2 = boto3.client('ec2')

def main():
    sgs = ec2.describe_security_groups()['SecurityGroups']
    for sg in sgs:
        for rule in sg.get('IpPermissions', []):
            for ip_range in rule.get('IpRanges', []):
                if ip_range.get('CidrIp') == '0.0.0.0/0' and rule.get('FromPort') in [22, 3389]:
                    print(f"Security group {sg['GroupId']} ({sg.get('GroupName')}) open on port {rule['FromPort']} to the world.")

if __name__ == "__main__":
    main()
