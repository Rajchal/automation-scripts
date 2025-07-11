import requests
import os
import yaml

GITHUB_TOKEN = "ghp_xxx"
OWNER = "your-org"
REPO = "your-repo"

headers = {"Authorization": f"token {GITHUB_TOKEN}"}

def get_secrets():
    url = f"https://api.github.com/repos/{OWNER}/{REPO}/actions/secrets"
    resp = requests.get(url, headers=headers)
    return [s['name'] for s in resp.json().get('secrets', [])]

def get_workflow_secrets():
    secrets_used = set()
    for root, _, files in os.walk(".github/workflows"):
        for file in files:
            if file.endswith(".yml") or file.endswith(".yaml"):
                with open(os.path.join(root, file)) as f:
                    try:
                        data = yaml.safe_load(f)
                        yml_str = str(data)
                        for secret in get_secrets():
                            if f"secrets.{secret}" in yml_str:
                                secrets_used.add(secret)
                    except Exception:
                        continue
    return secrets_used

def main():
    defined = set(get_secrets())
    used = get_workflow_secrets()
    unused = defined - used
    for secret in unused:
        print(f"Secret {secret} is not used in any workflow.")

if __name__ == "__main__":
    main()
