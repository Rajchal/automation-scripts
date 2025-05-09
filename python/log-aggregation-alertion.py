import os
import smtplib
from email.mime.text import MIMEText

LOG_DIR = "/var/log/myapp"
AGGREGATED_LOG = "/tmp/aggregated.log"
ALERT_EMAIL = "admin@example.com"

def aggregate_logs():
    print("Aggregating logs...")

    # Aggregate logs from all files in the directory
    with open(AGGREGATED_LOG, "w") as outfile:
        for log_file in os.listdir(LOG_DIR):
            log_path = os.path.join(LOG_DIR, log_file)
            if os.path.isfile(log_path):
                with open(log_path, "r") as infile:
                    outfile.write(infile.read())

    print(f"Logs aggregated to {AGGREGATED_LOG}")

def send_alert():
    print("Checking for critical errors...")
    with open(AGGREGATED_LOG, "r") as log:
        if "CRITICAL" in log.read():
            print("Critical error found! Sending alert...")

            # Send email alert
            msg = MIMEText("Critical error found in logs!")
            msg["Subject"] = "Critical Error Alert"
            msg["From"] = "no-reply@example.com"
            msg["To"] = ALERT_EMAIL

            with smtplib.SMTP("localhost") as server:
                server.send_message(msg)

if __name__ == "__main__":
    aggregate_logs()
    send_alert()
