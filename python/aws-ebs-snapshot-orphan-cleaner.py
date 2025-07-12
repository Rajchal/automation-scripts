import boto3

ec2 = boto3.client('ec2')

def main():
    snapshots = ec2.describe_snapshots(OwnerIds=['self'])['Snapshots']
    volumes = {v['VolumeId'] for v in ec2.describe_volumes()['Volumes']}
    for snap in snapshots:
        if snap.get('VolumeId') not in volumes:
            print(f"Orphaned snapshot: {snap['SnapshotId']} (Volume: {snap.get('VolumeId')})")
            # Uncomment to delete: ec2.delete_snapshot(SnapshotId=snap['SnapshotId'])

if __name__ == "__main__":
    main()
