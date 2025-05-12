import subprocess

def run_load_test(url, num_requests, concurrency):
    print(f"Starting load test for {url}...")

    # Run ApacheBench (ab) for load testing
    subprocess.run(["ab", "-n", str(num_requests), "-c", str(concurrency), url])

if __name__ == "__main__":
    url = input("Enter the target URL (e.g., https://example.com): ")
    num_requests = int(input("Enter the number of requests to send: "))
    concurrency = int(input("Enter the number of concurrent requests: "))
    run_load_test(url, num_requests, concurrency)
