import requests

# Send an alert to a Slack channel (Incoming Webhook URL required)
SLACK_WEBHOOK_URL = "https://hooks.slack.com/services/..."

def send_slack_alert(message):
    payload = {"text": message}
    resp = requests.post(SLACK_WEBHOOK_URL, json=payload)
    print("Slack response:", resp.text)

if __name__ == "__main__":
    send_slack_alert("🚨 DevOps Alert: Something needs your attention!")

