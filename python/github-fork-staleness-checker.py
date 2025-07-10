import requests
from datetime import datetime, timedelta

GITHUB_TOKEN = "ghp_xxx"
OWNER = "your-org"
REPO = "your-repo"
STALE_DAYS = 180

headers = {"Authorization": f"token {GITHUB_TOKEN}"}

def main():
    now = datetime.utcnow()
    forks = requests.get(f"https://api.github.com/repos/{OWNER}/{REPO}/forks", headers=headers).json()
    for fork in forks:
        pushed = datetime.strptime(fork['pushed_at'], "%Y-%m-%dT%H:%M:%SZ")
        days = (now - pushed).days
        if days > STALE_DAYS:
            print(f"Fork {fork['full_name']} is stale (last pushed {days} days ago).")

if __name__ == "__main__":
    main()
