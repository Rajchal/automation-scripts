import boto3

BUCKET = "your-bucket"
s3 = boto3.client('s3')

def main():
    resp = s3.list_objects_v2(Bucket=BUCKET)
    for obj in resp.get('Contents', []):
        acl = s3.get_object_acl(Bucket=BUCKET, Key=obj['Key'])
        for g in acl['Grants']:
            if g['Permission'] in ['READ', 'WRITE'] and g['Grantee'].get('URI', '').endswith('/AllUsers'):
                print(f"Object {obj['Key']} has public {g['Permission']} ACL")

if __name__ == "__main__":
    main()