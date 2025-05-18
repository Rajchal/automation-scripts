import requests
import json

# Script to dynamically update Cloudflare DNS record to current public IP

CLOUDFLARE_API = "https://api.cloudflare.com/client/v4"
API_TOKEN = "your-cloudflare-api-token"
ZONE_ID = "your-zone-id"
RECORD_ID = "your-record-id"
RECORD_NAME = "subdomain.example.com"

def get_public_ip():
    return requests.get("https://api.ipify.org").text

def update_dns(ip):
    url = f"{CLOUDFLARE_API}/zones/{ZONE_ID}/dns_records/{RECORD_ID}"
    headers = {"Authorization": f"Bearer {API_TOKEN}", "Content-Type": "application/json"}
    data = {
        "type": "A",
        "name": RECORD_NAME,
        "content": ip,
        "ttl": 1,
        "proxied": False
    }
    resp = requests.put(url, headers=headers, data=json.dumps(data))
    print("DNS Update Status:", resp.json())

if __name__ == "__main__":
    ip = get_public_ip()
    print("Public IP:", ip)
    update_dns(ip)
