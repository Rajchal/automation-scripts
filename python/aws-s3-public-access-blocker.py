import boto3

s3 = boto3.client('s3')

def main():
    for b in s3.list_buckets()['Buckets']:
        name = b['Name']
        s3.put_public_access_block(
            Bucket=name,
            PublicAccessBlockConfiguration={
                'BlockPublicAcls': True,
                'IgnorePublicAcls': True,
                'BlockPublicPolicy': True,
                'RestrictPublicBuckets': True
            }
        )
        print(f"Set public access block on {name}")

if __name__ == "__main__":
    main()