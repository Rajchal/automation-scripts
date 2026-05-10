#!/usr/bin/env python3
"""
GitHub Stale PR Closer
----------------------
This script connects to a specified GitHub repository and closes pull requests
that have been open and inactive for a certain number of days.

Prerequisites:
    pip install requests

Usage:
    export GITHUB_TOKEN="your_personal_access_token"
    python3 github-stale-pr-closer.py --repo "owner/repo" --days 30
"""

import os
import argparse
import sys
import datetime
import requests

def get_stale_prs(repo, days, token):
    headers = {
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github.v3+json"
    }
    url = f"https://api.github.com/repos/{repo}/pulls?state=open"
    
    response = requests.get(url, headers=headers)
    if response.status_code != 200:
        print(f"Error fetching PRs: {response.status_code} - {response.text}")
        sys.exit(1)
        
    prs = response.json()
    stale_prs = []
    
    cutoff_date = datetime.datetime.utcnow() - datetime.timedelta(days=days)
    
    for pr in prs:
        updated_at = datetime.datetime.strptime(pr['updated_at'], "%Y-%m-%dT%H:%M:%SZ")
        if updated_at < cutoff_date:
            stale_prs.append(pr)
            
    return stale_prs

def close_pr(repo, pr_number, token):
    headers = {
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github.v3+json"
    }
    url = f"https://api.github.com/repos/{repo}/pulls/{pr_number}"
    
    data = {
        "state": "closed"
    }
    
    response = requests.patch(url, headers=headers, json=data)
    if response.status_code == 200:
        print(f"Successfully closed PR #{pr_number}")
    else:
        print(f"Failed to close PR #{pr_number}: {response.status_code} - {response.text}")

def add_comment(repo, pr_number, token, comment):
    headers = {
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github.v3+json"
    }
    url = f"https://api.github.com/repos/{repo}/issues/{pr_number}/comments"
    
    data = {
        "body": comment
    }
    
    response = requests.post(url, headers=headers, json=data)
    if response.status_code == 201:
        print(f"Added comment to PR #{pr_number}")
    else:
        print(f"Failed to add comment to PR #{pr_number}: {response.status_code} - {response.text}")

def main():
    parser = argparse.ArgumentParser(description="Close stale GitHub Pull Requests")
    parser.add_argument("--repo", required=True, help="Repository in format owner/repo (e.g., octocat/Hello-World)")
    parser.add_argument("--days", type=int, default=30, help="Number of days of inactivity before closing (default: 30)")
    parser.add_argument("--dry-run", action="store_true", help="Print what would be done without actually doing it")
    
    args = parser.parse_args()
    
    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        print("Error: GITHUB_TOKEN environment variable is not set.")
        print("Please set it using: export GITHUB_TOKEN='your_token'")
        sys.exit(1)
        
    print(f"Scanning for PRs in {args.repo} inactive for more than {args.days} days...")
    
    stale_prs = get_stale_prs(args.repo, args.days, token)
    
    if not stale_prs:
        print("No stale PRs found.")
        return
        
    print(f"Found {len(stale_prs)} stale PR(s).")
    
    for pr in stale_prs:
        pr_number = pr['number']
        pr_title = pr['title']
        print(f"\nProcessing PR #{pr_number}: {pr_title}")
        
        if args.dry_run:
            print(f"[DRY-RUN] Would comment and close PR #{pr_number}")
        else:
            comment = f"This PR has been automatically closed because it has been inactive for more than {args.days} days. Please reopen if you wish to continue working on it."
            add_comment(args.repo, pr_number, token, comment)
            close_pr(args.repo, pr_number, token)

if __name__ == "__main__":
    main()
