import boto3

s3 = boto3.client('s3')

def main():
    for b in s3.list_buckets()['Buckets']:
        name = b['Name']
        try:
            enc = s3.get_bucket_encryption(Bucket=name)
        except s3.exceptions.ClientError:
            print(f"Bucket {name} has no default encryption enabled.")

if __name__ == "__main__":
    main()