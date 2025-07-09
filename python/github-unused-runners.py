import requests
from datetime import datetime, timedelta

GITHUB_TOKEN = 'ghp_xxx'
ORG = 'your-org'
DAYS = 7
HEADERS = {'Authorization': f'token {GITHUB_TOKEN}'}

def main():
    runners = requests.get(f'https://api.github.com/orgs/{ORG}/actions/runners', headers=HEADERS).json()['runners']
    cutoff = datetime.utcnow() - timedelta(days=DAYS)
    for runner in runners:
        jobs = requests.get(
            f"https://api.github.com/orgs/{ORG}/actions/runners/{runner['id']}/jobs",
            headers=HEADERS).json().get('jobs', [])
        recent = any(
            datetime.strptime(j['started_at'], "%Y-%m-%dT%H:%M:%SZ") > cutoff
            for j in jobs
        )
        if not recent:
            print(f"Runner {runner['name']} unused for {DAYS} days.")

if __name__ == "__main__":
    main()
