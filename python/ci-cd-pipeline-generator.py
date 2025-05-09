import os

def generate_ci_cd_pipeline():
    print("Generating CI/CD pipeline...")

    # Create .github/workflows directory if it doesn't exist
    os.makedirs(".github/workflows", exist_ok=True)

    # Write the pipeline YAML file
    pipeline = """name: CI/CD Pipeline

on:
  push:
    branches:
      - main

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v3

      - name: Set up Python
        uses: actions/setup-python@v4
        with:
          python-version: 3.9

      - name: Install dependencies
        run: pip install -r requirements.txt

      - name: Run tests
        run: pytest

      - name: Deploy to production
        if: github.ref == 'refs/heads/main'
        run: echo "Deploying to production..."
    """
    with open(".github/workflows/ci_cd_pipeline.yml", "w") as f:
        f.write(pipeline)

    print("CI/CD pipeline generated at .github/workflows/ci_cd_pipeline.yml")

if __name__ == "__main__":
    generate_ci_cd_pipeline()
