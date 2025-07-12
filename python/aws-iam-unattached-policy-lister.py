import boto3

iam = boto3.client('iam')

def main():
    paginator = iam.get_paginator('list_policies')
    for page in paginator.paginate(Scope='Local'):
        for policy in page['Policies']:
            attached = policy['AttachmentCount']
            if attached == 0:
                print(f"Unattached policy: {policy['PolicyName']} ({policy['Arn']})")

if __name__ == "__main__":
    main()
