import requests
import re

GITHUB_TOKEN = "ghp_xxx"
ORG = "your-org"
SECRET_PATTERNS = [
    re.compile(r"AKIA[0-9A-Z]{16}"),  # AWS key example
    re.compile(r"ghp_[A-Za-z0-9]{36}"),  # GitHub token
]

headers = {"Authorization": f"token {GITHUB_TOKEN}"}
repos = requests.get(f"https://api.github.com/orgs/{ORG}/repos", headers=headers).json()

for repo in repos:
    name = repo['full_name']
    files = requests.get(f"https://api.github.com/repos/{name}/git/trees/main?recursive=1", headers=headers).json()
    for f in files.get('tree', []):
        if f['type'] == 'blob' and f['path'].endswith(('.py', '.js', '.env')):
            content = requests.get(f"https://raw.githubusercontent.com/{name}/main/{f['path']}", headers=headers).text
            for pattern in SECRET_PATTERNS:
                for match in pattern.findall(content):
                    print(f"Secret found in {name}/{f['path']}: {match}")
