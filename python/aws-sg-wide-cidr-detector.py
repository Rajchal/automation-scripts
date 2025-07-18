import boto3

SENSITIVE_PORTS = {22, 3389}
ec2 = boto3.client('ec2')

def main():
    sgs = ec2.describe_security_groups()['SecurityGroups']
    for sg in sgs:
        for rule in sg.get('IpPermissions', []):
            if 'FromPort' in rule and 'ToPort' in rule:
                if any(ipr.get('CidrIp', '') == '0.0.0.0/0' for ipr in rule.get('IpRanges', [])):
                    ports = set(range(rule['FromPort'], rule['ToPort']+1))
                    if SENSITIVE_PORTS & ports:
                        print(f"Security Group {sg['GroupId']} allows 0.0.0.0/0 on ports {rule['FromPort']}-{rule['ToPort']}")

if __name__ == "__main__":
    main()