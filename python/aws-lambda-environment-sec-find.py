import boto3
import re

PATTERNS = [re.compile(r'key', re.I), re.compile(r'token', re.I), re.compile(r'pass', re.I)]
lambda_client = boto3.client('lambda')

def looks_like_secret(var):
    return any(p.search(var) for p in PATTERNS)

def main():
    funcs = lambda_client.list_functions()['Functions']
    for f in funcs:
        env = f.get('Environment', {}).get('Variables', {})
        secrets = [k for k in env if looks_like_secret(k)]
        if secrets:
            print(f"Function {f['FunctionName']} has possible secrets in env: {secrets}")

if __name__ == "__main__":
    main()
