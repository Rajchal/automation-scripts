#!/usr/bin/env python3
"""
AWS S3 Bucket Size Calculator
-----------------------------
This script retrieves the total size and object count of all S3 buckets (or a specific bucket)
in an AWS account using CloudWatch metrics.

This method is much faster than iterating through all objects in a bucket using the S3 API.

Prerequisites:
    pip install boto3

Usage:
    python3 aws-s3-bucket-size-calculator.py
    python3 aws-s3-bucket-size-calculator.py --bucket my-specific-bucket --region us-east-1
"""

import argparse
import datetime
import boto3
from botocore.exceptions import ClientError

def get_bucket_size(cloudwatch, bucket_name):
    """
    Get the size of a bucket in bytes using CloudWatch metrics.
    """
    try:
        response = cloudwatch.get_metric_statistics(
            Namespace='AWS/S3',
            MetricName='BucketSizeBytes',
            Dimensions=[
                {'Name': 'BucketName', 'Value': bucket_name},
                {'Name': 'StorageType', 'Value': 'StandardStorage'}
            ],
            StartTime=datetime.datetime.utcnow() - datetime.timedelta(days=2),
            EndTime=datetime.datetime.utcnow(),
            Period=86400,
            Statistics=['Average']
        )
        if response['Datapoints']:
            return response['Datapoints'][-1]['Average']
        return 0
    except ClientError as e:
        print(f"Error getting size for bucket {bucket_name}: {e}")
        return 0

def get_bucket_object_count(cloudwatch, bucket_name):
    """
    Get the number of objects in a bucket using CloudWatch metrics.
    """
    try:
        response = cloudwatch.get_metric_statistics(
            Namespace='AWS/S3',
            MetricName='NumberOfObjects',
            Dimensions=[
                {'Name': 'BucketName', 'Value': bucket_name},
                {'Name': 'StorageType', 'Value': 'AllStorageTypes'}
            ],
            StartTime=datetime.datetime.utcnow() - datetime.timedelta(days=2),
            EndTime=datetime.datetime.utcnow(),
            Period=86400,
            Statistics=['Average']
        )
        if response['Datapoints']:
            return response['Datapoints'][-1]['Average']
        return 0
    except ClientError as e:
        print(f"Error getting object count for bucket {bucket_name}: {e}")
        return 0

def format_size(size_bytes):
    """
    Format bytes to human readable format.
    """
    if size_bytes == 0:
        return "0 B"
    size_name = ("B", "KB", "MB", "GB", "TB", "PB")
    import math
    i = int(math.floor(math.log(size_bytes, 1024)))
    p = math.pow(1024, i)
    s = round(size_bytes / p, 2)
    return f"{s} {size_name[i]}"

def main():
    parser = argparse.ArgumentParser(description="Calculate S3 bucket sizes using CloudWatch")
    parser.add_argument("--bucket", help="Specific bucket name to check. If omitted, checks all buckets.")
    parser.add_argument("--region", default="us-east-1", help="AWS region (default: us-east-1)")
    
    args = parser.parse_args()
    
    print(f"Connecting to AWS region: {args.region}...")
    
    try:
        s3 = boto3.client('s3', region_name=args.region)
        cloudwatch = boto3.client('cloudwatch', region_name=args.region)
    except Exception as e:
        print(f"Failed to initialize AWS clients. Please check your credentials. Error: {e}")
        return
        
    buckets_to_check = []
    
    if args.bucket:
        buckets_to_check.append(args.bucket)
    else:
        print("Fetching list of all buckets...")
        try:
            response = s3.list_buckets()
            buckets_to_check = [bucket['Name'] for bucket in response['Buckets']]
        except ClientError as e:
            print(f"Failed to list buckets: {e}")
            return
            
    print(f"Found {len(buckets_to_check)} bucket(s) to analyze.\n")
    print("-" * 80)
    print(f"{'Bucket Name':<40} | {'Object Count':<15} | {'Total Size':<20}")
    print("-" * 80)
    
    total_size = 0
    total_objects = 0
    
    for bucket in buckets_to_check:
        size_bytes = get_bucket_size(cloudwatch, bucket)
        obj_count = get_bucket_object_count(cloudwatch, bucket)
        
        total_size += size_bytes
        total_objects += obj_count
        
        formatted_size = format_size(size_bytes)
        print(f"{bucket:<40} | {int(obj_count):<15} | {formatted_size:<20}")
        
    print("-" * 80)
    print(f"{'TOTAL':<40} | {int(total_objects):<15} | {format_size(total_size):<20}")
    print("-" * 80)
    
    print("\nNote: CloudWatch metrics are typically updated once a day.")
    print("These numbers reflect the most recent data point available (up to 48 hours old).")

if __name__ == "__main__":
    main()
