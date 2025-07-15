import boto3

iam = boto3.client('iam')

def main():
    users = iam.list_users()['Users']
    for user in users:
        mfa = iam.list_mfa_devices(UserName=user['UserName'])['MFADevices']
        if not mfa:
            print(f"User {user['UserName']} does not have MFA enabled")

if __name__ == "__main__":
    main()