import boto3
from datetime import datetime, timezone, timedelta

BUCKET = "your-bucket"
DAYS = 30
DELETE = False  # Set to True to delete

s3 = boto3.client('s3')

def main():
    cutoff = datetime.now(timezone.utc) - timedelta(days=DAYS)
    objects = s3.list_objects_v2(Bucket=BUCKET).get('Contents', [])
    for obj in objects:
        lastmod = obj['LastModified']
        if lastmod < cutoff:
            print(f"Old object: {obj['Key']} (last modified {lastmod})")
            if DELETE:
                s3.delete_object(Bucket=BUCKET, Key=obj['Key'])
                print(f"Deleted: {obj['Key']}")

if __name__ == "__main__":
    main()
