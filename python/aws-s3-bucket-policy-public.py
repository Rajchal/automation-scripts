import boto3
import json

s3 = boto3.client('s3')

def main():
    for b in s3.list_buckets()['Buckets']:
        name = b['Name']
        try:
            pol = s3.get_bucket_policy(Bucket=name)['Policy']
            polj = json.loads(pol)
            for stmt in polj['Statement']:
                if stmt.get('Effect') == 'Allow' and stmt.get('Principal') == '*':
                    print(f"Bucket {name} has a public policy!")
        except Exception:
            continue

if __name__ == "__main__":
    main()
