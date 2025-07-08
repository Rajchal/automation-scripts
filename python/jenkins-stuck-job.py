import requests
from datetime import datetime, timezone

JENKINS_URL = 'http://jenkins.local:8080'
USER = 'admin'
TOKEN = 'your_api_token'
THRESHOLD_HOURS = 3

def main():
    jobs = requests.get(f"{JENKINS_URL}/api/json?tree=jobs[name,url]", auth=(USER, TOKEN)).json()['jobs']
    for job in jobs:
        builds = requests.get(f"{job['url']}api/json?tree=builds[number,url,building,timestamp]", auth=(USER, TOKEN)).json()['builds']
        for build in builds:
            if build['building']:
                start = datetime.fromtimestamp(build['timestamp']/1000, tz=timezone.utc)
                hours = (datetime.now(timezone.utc) - start).total_seconds() / 3600
                if hours > THRESHOLD_HOURS:
                    print(f"Stuck job: {job['name']} build #{build['number']} running for {hours:.1f} hours.")

if __name__ == "__main__":
    main()
