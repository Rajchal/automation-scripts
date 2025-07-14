import boto3

lambda_client = boto3.client('lambda')
THRESHOLD = 60

def main():
    funcs = lambda_client.list_functions()['Functions']
    for f in funcs:
        if f['Timeout'] > THRESHOLD:
            print(f"Function {f['FunctionName']} timeout is {f['Timeout']} seconds")

if __name__ == "__main__":
    main()