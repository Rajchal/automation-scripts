import requests
import yaml

CLOUDFLARE_API_TOKEN = "your-token"
ZONE_ID = "your-zone-id"
RECORDS_FILE = "expected_dns.yaml"

def get_cloudflare_dns():
    url = f'https://api.cloudflare.com/client/v4/zones/{ZONE_ID}/dns_records'
    headers = {"Authorization": f"Bearer {CLOUDFLARE_API_TOKEN}"}
    resp = requests.get(url, headers=headers)
    return {(r['name'], r['type']): r['content'] for r in resp.json()['result']}

def get_expected_dns():
    with open(RECORDS_FILE) as f:
        data = yaml.safe_load(f)
    return {(r['name'], r['type']): r['content'] for r in data['records']}

def main():
    cf = get_cloudflare_dns()
    expected = get_expected_dns()
    drift = []
    for k, v in expected.items():
        if cf.get(k) != v:
            drift.append(f"Drift for {k}: expected {v}, found {cf.get(k)}")
    if drift:
        print("\n".join(drift))
    else:
        print("No drift detected.")

if __name__ == "__main__":
    main()
