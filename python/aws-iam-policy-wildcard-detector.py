import boto3
import json

iam = boto3.client('iam')

def check_policy(policy_doc, policy_name):
    for stmt in policy_doc.get('Statement', []):
        if stmt.get('Action') == "*" or stmt.get('Resource') == "*":
            print(f"Wildcard found in policy {policy_name}")

def main():
    paginator = iam.get_paginator('list_policies')
    for page in paginator.paginate(Scope='Local'):
        for policy in page['Policies']:
            v = iam.get_policy_version(
                PolicyArn=policy['Arn'],
                VersionId=policy['DefaultVersionId']
            )
            doc = v['PolicyVersion']['Document']
            check_policy(doc, policy['PolicyName'])

    users = iam.list_users()['Users']
    for user in users:
        for p in iam.list_user_policies(UserName=user['UserName'])['PolicyNames']:
            doc = iam.get_user_policy(UserName=user['UserName'], PolicyName=p)['PolicyDocument']
            check_policy(doc, f"user/{user['UserName']}/{p}")

if __name__ == "__main__":
    main()
