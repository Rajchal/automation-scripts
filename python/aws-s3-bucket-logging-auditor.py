import boto3

s3 = boto3.client('s3')

def main():
    for b in s3.list_buckets()['Buckets']:
        name = b['Name']
        logging = s3.get_bucket_logging(Bucket=name)
        if "LoggingEnabled" not in logging:
            print(f"Bucket {name} does not have access logging enabled.")

if __name__ == "__main__":
    main()