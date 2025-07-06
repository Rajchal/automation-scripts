import boto3

ec2 = boto3.client('ec2')

def main():
    volumes = ec2.describe_volumes(Filters=[{'Name': 'status', 'Values': ['available']}])['Volumes']
    if not volumes:
        print("No orphaned volumes found.")
    for v in volumes:
        print(f"Orphaned EBS volume: {v['VolumeId']} ({v['Size']} GiB, created {v['CreateTime']})")

if __name__ == "__main__":
    main()
