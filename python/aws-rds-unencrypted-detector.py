import boto3

rds = boto3.client('rds')

def main():
    instances = rds.describe_db_instances()['DBInstances']
    for inst in instances:
        if not inst.get('StorageEncrypted', False):
            print(f"RDS Instance {inst['DBInstanceIdentifier']} is unencrypted!")

if __name__ == "__main__":
    main()
