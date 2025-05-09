import requests
import secrets

VAULT_API = "https://vault.myorg.com/v1/myapp/secrets"
API_TOKEN = "your-vault-api-token"

def rotate_secrets():
    print("Rotating secrets...")

    # Generate a new secret
    new_secret = secrets.token_urlsafe(32)

    # Update the secret in Vault
    response = requests.post(
        VAULT_API,
        headers={"Authorization": f"Bearer {API_TOKEN}", "Content-Type": "application/json"},
        json={"new_secret": new_secret},
    )

    if response.status_code == 200:
        print("Secrets rotated successfully!")
    else:
        print("Failed to rotate secrets:", response.text)

if __name__ == "__main__":
    rotate_secrets()
