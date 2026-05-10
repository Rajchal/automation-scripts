#!/usr/bin/env python3
"""
AWS IAM Role Policy Diff
------------------------
This tool compares the attached managed policies and inline policies
of two AWS IAM roles and outputs the differences.

Prerequisites:
    pip install boto3

Usage:
    python3 aws-iam-role-policy-diff.py --role1 OldRole --role2 NewRole
"""

import argparse
import boto3
from botocore.exceptions import ClientError
import sys

def get_role_managed_policies(iam, role_name):
    policies = set()
    try:
        paginator = iam.get_paginator('list_attached_role_policies')
        for page in paginator.paginate(RoleName=role_name):
            for policy in page['AttachedPolicies']:
                policies.add(policy['PolicyArn'])
        return policies
    except ClientError as e:
        print(f"Error fetching managed policies for {role_name}: {e}")
        sys.exit(1)

def get_role_inline_policies(iam, role_name):
    policies = set()
    try:
        paginator = iam.get_paginator('list_role_policies')
        for page in paginator.paginate(RoleName=role_name):
            for policy_name in page['PolicyNames']:
                policies.add(policy_name)
        return policies
    except ClientError as e:
        print(f"Error fetching inline policies for {role_name}: {e}")
        sys.exit(1)

def print_diff(name, items1, items2, role1_name, role2_name):
    print(f"\n=== {name} ===")
    
    only_in_1 = items1 - items2
    only_in_2 = items2 - items1
    common = items1.intersection(items2)
    
    if not only_in_1 and not only_in_2:
        print("✅ Identical")
        return
        
    if common:
        print("\nCommon in both:")
        for item in sorted(common):
            print(f"  = {item}")
            
    if only_in_1:
        print(f"\nOnly in {role1_name}:")
        for item in sorted(only_in_1):
            print(f"  - {item}")
            
    if only_in_2:
        print(f"\nOnly in {role2_name}:")
        for item in sorted(only_in_2):
            print(f"  + {item}")

def main():
    parser = argparse.ArgumentParser(description="Compare IAM policies between two roles")
    parser.add_argument("--role1", required=True, help="First role name")
    parser.add_argument("--role2", required=True, help="Second role name")
    parser.add_argument("--region", default="us-east-1", help="AWS region")
    
    args = parser.parse_args()
    
    try:
        iam = boto3.client('iam', region_name=args.region)
    except Exception as e:
        print(f"Failed to initialize AWS client. Please check credentials. Error: {e}")
        return
        
    print(f"Comparing roles: {args.role1} vs {args.role2}...\n")
    
    # Managed Policies
    managed1 = get_role_managed_policies(iam, args.role1)
    managed2 = get_role_managed_policies(iam, args.role2)
    print_diff("Managed Policies (ARNs)", managed1, managed2, args.role1, args.role2)
    
    # Inline Policies
    inline1 = get_role_inline_policies(iam, args.role1)
    inline2 = get_role_inline_policies(iam, args.role2)
    print_diff("Inline Policies (Names)", inline1, inline2, args.role1, args.role2)

if __name__ == "__main__":
    main()
