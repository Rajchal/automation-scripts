import boto3

iam = boto3.client('iam')

def main():
    for user in iam.list_users()['Users']:
        policies = iam.list_user_policies(UserName=user['UserName'])['PolicyNames']
        if policies:
            print(f"User {user['UserName']} has inline policies: {policies}")
    for role in iam.list_roles()['Roles']:
        policies = iam.list_role_policies(RoleName=role['RoleName'])['PolicyNames']
        if policies:
            print(f"Role {role['RoleName']} has inline policies: {policies}")
    for group in iam.list_groups()['Groups']:
        policies = iam.list_group_policies(GroupName=group['GroupName'])['PolicyNames']
        if policies:
            print(f"Group {group['GroupName']} has inline policies: {policies}")

if __name__ == "__main__":
    main()