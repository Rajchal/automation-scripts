import boto3
from datetime import datetime, timezone, timedelta

BUCKET = "your-bucket"
THRESHOLD_DAYS = 7
s3 = boto3.client('s3')

def main():
    now = datetime.now(timezone.utc)
    uploads = s3.list_multipart_uploads(Bucket=BUCKET).get('Uploads', [])
    for upload in uploads:
        initiated = upload['Initiated']
        age = (now - initiated).days
        if age > THRESHOLD_DAYS:
            print(f"Abandoned multipart upload: {upload['Key']} initiated {age} days ago (UploadId: {upload['UploadId']})")

if __name__ == "__main__":
    main()