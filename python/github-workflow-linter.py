import os
import yaml

WORKFLOW_DIR = ".github/workflows"

def lint_yaml(path):
    try:
        with open(path) as f:
            data = yaml.safe_load(f)
        if 'jobs' not in data:
            print(f"Missing 'jobs' in {path}")
    except Exception as e:
        print(f"Error in {path}: {e}")

def main():
    for fname in os.listdir(WORKFLOW_DIR):
        if fname.endswith('.yml') or fname.endswith('.yaml'):
            lint_yaml(os.path.join(WORKFLOW_DIR, fname))

if __name__ == "__main__":
    main()
