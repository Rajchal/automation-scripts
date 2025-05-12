import os
import subprocess
import smtplib
from email.mime.text import MIMEText

THRESHOLD_MINUTES = 5
ALERT_EMAIL = "admin@example.com"

def check_uptime():
    print("Checking server uptime...")

    # Get uptime in seconds
    uptime_seconds = float(subprocess.check_output(["cat", "/proc/uptime"]).split()[0])
    uptime_minutes = int(uptime_seconds / 60)

    if uptime_minutes < THRESHOLD_MINUTES:
        print(f"Server uptime is below threshold: {uptime_minutes} minutes. Sending alert...")
        send_alert(uptime_minutes)
    else:
        print(f"Server uptime is healthy: {uptime_minutes} minutes.")

def send_alert(uptime_minutes):
    # Send an email alert
    subject = "Server Uptime Alert"
    body = f"Server uptime is only {uptime_minutes} minutes. Check the server immediately."
    msg = MIMEText(body)
    msg["Subject"] = subject
    msg["From"] = "no-reply@example.com"
    msg["To"] = ALERT_EMAIL

    with smtplib.SMTP("localhost") as server:
        server.send_message(msg)
    print("Alert email sent!")

if __name__ == "__main__":
    check_uptime()
