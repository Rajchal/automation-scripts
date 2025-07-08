import os
import re

def lint_dockerfile(path):
    with open(path) as f:
        content = f.read()
    if "FROM" in content and ":latest" in content:
        print(f"{path}: Avoid using 'latest' tag in FROM statement.")
    if "LABEL" not in content:
        print(f"{path}: Consider adding LABEL for maintainer or version.")

def main():
    for root, _, files in os.walk("."):
        for file in files:
            if file == "Dockerfile":
                lint_dockerfile(os.path.join(root, file))

if __name__ == "__main__":
    main()
