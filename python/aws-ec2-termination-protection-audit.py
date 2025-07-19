import boto3

ec2 = boto3.client('ec2')

def main():
    reservations = ec2.describe_instances()['Reservations']
    for res in reservations:
        for inst in res['Instances']:
            attr = ec2.describe_instance_attribute(InstanceId=inst['InstanceId'], Attribute='disableApiTermination')
            if not attr['DisableApiTermination']['Value']:
                print(f"Instance {inst['InstanceId']} does NOT have termination protection enabled.")

if __name__ == "__main__":
    main()