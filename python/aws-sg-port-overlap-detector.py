import boto3

ec2 = boto3.client('ec2')

def overlaps(a, b):
    return max(a[0], b[0]) <= min(a[1], b[1])

def main():
    sgs = ec2.describe_security_groups()['SecurityGroups']
    for sg in sgs:
        ports = []
        for rule in sg.get('IpPermissions', []):
            if 'FromPort' in rule and 'ToPort' in rule:
                ports.append((rule['FromPort'], rule['ToPort']))
        for i in range(len(ports)):
            for j in range(i+1, len(ports)):
                if overlaps(ports[i], ports[j]):
                    print(f"Security group {sg['GroupId']} ({sg.get('GroupName')}) has overlapping ranges: {ports[i]} & {ports[j]}")

if __name__ == "__main__":
    main()
