import os
import subprocess

def setup_environment():
    print("Starting environment setup...")

    # Input environment name
    env = input("Enter the environment name (dev/staging/prod): ").strip().lower()

    # Validate input
    if env not in ["dev", "staging", "prod"]:
        print("Invalid environment. Choose 'dev', 'staging', or 'prod'.")
        return

    # Install dependencies based on the environment
    if env == "dev":
        print("Installing development dependencies...")
        subprocess.run(["sudo", "apt-get", "update"])
        subprocess.run(["sudo", "apt-get", "install", "-y", "git", "curl"])
    elif env == "staging":
        print("Setting up staging environment...")
        subprocess.run(["sudo", "apt-get", "update"])
        subprocess.run(["sudo", "apt-get", "install", "-y", "nginx"])
    elif env == "prod":
        print("Setting up production environment...")
        subprocess.run(["sudo", "apt-get", "update"])
        subprocess.run(["sudo", "apt-get", "install", "-y", "docker.io"])

    # Setting environment variables
    print(f"Setting up environment variables for {env}...")
    os.environ["ENVIRONMENT"] = env
    os.environ["APP_PORT"] = "8080"

    print(f"Environment {env} setup complete!")

if __name__ == "__main__":
    setup_environment()
