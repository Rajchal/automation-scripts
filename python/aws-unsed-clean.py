import boto3

def cleanup_unused_resources():
    print("Cleaning up unused AWS resources...")

    ec2 = boto3.client("ec2")

    # Delete unused EC2 volumes
    volumes = ec2.describe_volumes(Filters=[{"Name": "status", "Values": ["available"]}])["Volumes"]
    for volume in volumes:
        volume_id = volume["VolumeId"]
        print(f"Deleting unused volume: {volume_id}")
        ec2.delete_volume(VolumeId=volume_id)

    # Delete snapshots older than 30 days
    snapshots = ec2.describe_snapshots(OwnerIds=["self"])["Snapshots"]
    for snapshot in snapshots:
        snapshot_id = snapshot["SnapshotId"]
        start_time = snapshot["StartTime"]
        if (datetime.now(snapshot["StartTime"].tzinfo) - start_time).days > 30:
            print(f"Deleting old snapshot: {snapshot_id}")
            ec2.delete_snapshot(SnapshotId=snapshot_id)

if __name__ == "__main__":
    cleanup_unused_resources()
