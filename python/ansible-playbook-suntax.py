import os
import subprocess

def main():
    for root, _, files in os.walk("."):
        for file in files:
            if file.endswith(".yml") or file.endswith(".yaml"):
                path = os.path.join(root, file)
                result = subprocess.run(['ansible-playbook', '--syntax-check', path], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                if result.returncode != 0:
                    print(f"Syntax error in {path}:\n{result.stderr.decode()}")

if __name__ == "__main__":
    main()
