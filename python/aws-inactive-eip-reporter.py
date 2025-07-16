import boto3

ec2 = boto3.client('ec2')

def main():
    eips = ec2.describe_addresses()['Addresses']
    for eip in eips:
        if 'InstanceId' not in eip or not eip['InstanceId']:
            print(f"Elastic IP {eip['PublicIp']} is not attached to any instance.")

if __name__ == "__main__":
    main()