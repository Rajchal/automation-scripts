import requests

# Remove offline GitLab runners

GITLAB_URL = "https://gitlab.example.com"
PRIVATE_TOKEN = "your-token"

def cleanup_offline_runners():
    url = f"{GITLAB_URL}/api/v4/runners/all"
    headers = {"PRIVATE-TOKEN": PRIVATE_TOKEN}
    runners = requests.get(url, headers=headers).json()
    for runner in runners:
        if runner['status'] == 'offline':
            print(f"Removing runner {runner['id']} ({runner['description']})")
            delete_url = f"{GITLAB_URL}/api/v4/runners/{runner['id']}"
            requests.delete(delete_url, headers=headers)

if __name__ == "__main__":
    cleanup_offline_runners()
