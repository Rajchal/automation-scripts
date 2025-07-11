import requests

GITHUB_TOKEN = "ghp_xxx"
ORG = "your-org"
ALLOWED = ["main", "master"]

headers = {"Authorization": f"token {GITHUB_TOKEN}"}

def main():
    repos = requests.get(f"https://api.github.com/orgs/{ORG}/repos", headers=headers).json()
    for repo in repos:
        if repo['default_branch'] not in ALLOWED:
            print(f"{repo['full_name']} default branch is {repo['default_branch']}")

if __name__ == "__main__":
    main()
