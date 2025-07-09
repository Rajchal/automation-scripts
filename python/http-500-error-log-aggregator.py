import re
from collections import Counter

LOG_PATH = "/var/log/nginx/access.log"

def main():
    counter = Counter()
    with open(LOG_PATH) as f:
        for line in f:
            m = re.search(r'\"[A-Z]+ ([^ ]+) HTTP/[^"]+\" 500', line)
            if m:
                counter[m.group(1)] += 1
    for url, count in counter.most_common():
        if count > 5:
            print(f"URL {url} had {count} HTTP 500 errors.")

if __name__ == "__main__":
    main()
