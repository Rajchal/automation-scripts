import os
import subprocess

def lint_dockerfiles(root='.'):
    for dirpath, dirnames, filenames in os.walk(root):
        for fname in filenames:
            if fname == "Dockerfile":
                fpath = os.path.join(dirpath, fname)
                print(f"Linting {fpath}...")
                subprocess.run(["hadolint", fpath])

if __name__ == "__main__":
    lint_dockerfiles()
