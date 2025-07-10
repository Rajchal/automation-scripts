import requests

GITHUB_TOKEN = "ghp_xxx"
ORG = "your-org"
WORKFLOW_NAME = "main.yml"  # Name of the workflow file to dispatch

headers = {"Authorization": f"token {GITHUB_TOKEN}", "Accept": "application/vnd.github+json"}

def main():
    repos = requests.get(f"https://api.github.com/orgs/{ORG}/repos", headers=headers).json()
    for repo in repos:
        owner, name = ORG, repo['name']
        url = f"https://api.github.com/repos/{owner}/{name}/actions/workflows/{WORKFLOW_NAME}/dispatches"
        resp = requests.post(url, headers=headers, json={"ref": "main"})
        print(f"{name}: Triggered, status {resp.status_code}")

if __name__ == "__main__":
    main()
