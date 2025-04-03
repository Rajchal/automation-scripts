import requests
try:
    response = requests.get("http://api.your-service.com")
    if response.status_code != 200:
        print("Service Down Alert!")
except Exception:
    print("Service Unreachable!")
