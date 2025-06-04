import requests

# Monitor Jenkins jobs and alert on failures

JENKINS_URL = "https://jenkins.example.com"
JENKINS_USER = "your-username"
JENKINS_TOKEN = "your-token"

def monitor_jenkins():
    url = f"{JENKINS_URL}/api/json"
    response = requests.get(url, auth=(JENKINS_USER, JENKINS_TOKEN))
    jobs = response.json().get('jobs', [])
    for job in jobs:
        job_url = job['url'] + "lastBuild/api/json"
        job_resp = requests.get(job_url, auth=(JENKINS_USER, JENKINS_TOKEN))
        result = job_resp.json().get('result')
        if result and result != "SUCCESS":
            print(f"Jenkins job failed: {job['name']} - Status: {result}")

if __name__ == "__main__":
    monitor_jenkins()
