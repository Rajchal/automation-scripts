#!/usr/bin/env python3
"""
MongoDB Backup to S3
--------------------
This script creates a backup of a MongoDB database using `mongodump`,
compresses it, and uploads the archive to an AWS S3 bucket.

Prerequisites:
    pip install boto3
    mongodump (must be installed on the system)

Usage:
    export MONGO_URI="mongodb://user:pass@localhost:27017/mydb"
    export S3_BUCKET="my-backup-bucket"
    python3 mongodb-backup-to-s3.py --db mydb --bucket $S3_BUCKET
"""

import os
import sys
import subprocess
import datetime
import argparse
import boto3
from botocore.exceptions import ClientError

def dump_database(mongo_uri, db_name, out_dir):
    """
    Dumps the MongoDB database using mongodump and returns the path to the compressed archive.
    """
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    archive_name = f"{db_name}_{timestamp}.archive.gz"
    archive_path = os.path.join(out_dir, archive_name)
    
    print(f"Starting mongodump for database '{db_name}'...")
    
    cmd = [
        "mongodump",
        "--uri", mongo_uri,
        "--db", db_name,
        "--archive=" + archive_path,
        "--gzip"
    ]
    
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        print(f"Successfully created backup archive: {archive_path}")
        return archive_path
    except subprocess.CalledProcessError as e:
        print(f"Error running mongodump: {e.stderr.decode('utf-8')}")
        sys.exit(1)
    except FileNotFoundError:
        print("Error: 'mongodump' command not found. Please ensure MongoDB tools are installed.")
        sys.exit(1)

def upload_to_s3(file_path, bucket_name, s3_prefix=""):
    """
    Uploads a file to an AWS S3 bucket.
    """
    s3_client = boto3.client('s3')
    file_name = os.path.basename(file_path)
    
    s3_key = f"{s3_prefix.strip('/')}/{file_name}" if s3_prefix else file_name
    
    print(f"Uploading {file_name} to s3://{bucket_name}/{s3_key} ...")
    
    try:
        s3_client.upload_file(file_path, bucket_name, s3_key)
        print("Upload successful!")
    except ClientError as e:
        print(f"Failed to upload to S3: {e}")
        sys.exit(1)

def main():
    parser = argparse.ArgumentParser(description="Backup MongoDB and upload to S3")
    parser.add_argument("--db", required=True, help="MongoDB database name to backup")
    parser.add_argument("--bucket", required=True, help="AWS S3 bucket name")
    parser.add_argument("--s3-prefix", default="mongodb-backups", help="Prefix/folder path in S3 bucket")
    parser.add_argument("--temp-dir", default="/tmp", help="Temporary directory to store the archive before upload")
    
    args = parser.parse_args()
    
    mongo_uri = os.environ.get("MONGO_URI")
    if not mongo_uri:
        print("Error: MONGO_URI environment variable is not set.")
        sys.exit(1)
        
    archive_path = dump_database(mongo_uri, args.db, args.temp_dir)
    
    upload_to_s3(archive_path, args.bucket, args.s3_prefix)
    
    # Cleanup local file
    print(f"Cleaning up local archive {archive_path}...")
    try:
        os.remove(archive_path)
        print("Cleanup complete.")
    except OSError as e:
        print(f"Warning: Failed to remove local archive: {e}")

if __name__ == "__main__":
    main()
