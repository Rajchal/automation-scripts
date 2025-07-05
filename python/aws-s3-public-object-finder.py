import boto3

s3 = boto3.client('s3')

def is_public(bucket, key):
    acl = s3.get_object_acl(Bucket=bucket, Key=key)
    for grant in acl['Grants']:
        if grant['Grantee'].get('URI') == 'http://acs.amazonaws.com/groups/global/AllUsers':
            return True
    return False

def main():
    for bucket in s3.list_buckets()['Buckets']:
        name = bucket['Name']
        for obj in s3.list_objects_v2(Bucket=name).get('Contents', []):
            key = obj['Key']
            try:
                if is_public(name, key):
                    print(f"Public object: s3://{name}/{key}")
            except Exception:
                continue

if __name__ == "__main__":
    main()
