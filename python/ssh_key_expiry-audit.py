import datetime
import re
import smtplib
from email.mime.text import MIMEText

AUTHORIZED_KEYS_PATH = "/home/youruser/.ssh/authorized_keys"
USER_EMAIL = "admin@example.com"
DATE_PATTERN = re.compile(r'expiry=(\d{4}-\d{2}-\d{2})')

def check_keys():
    expired = []
    with open(AUTHORIZED_KEYS_PATH) as f:
        for line in f:
            match = DATE_PATTERN.search(line)
            if match:
                expiry = datetime.datetime.strptime(match.group(1), "%Y-%m-%d").date()
                if expiry < datetime.date.today():
                    expired.append(line.strip())
    return expired

def send_alert(keys):
    if not keys:
        return
    msg = MIMEText("Expired SSH keys found:\n\n" + "\n".join(keys))
    msg['Subject'] = 'Expired SSH Key(s) Detected'
    msg['From'] = USER_EMAIL
    msg['To'] = USER_EMAIL
    with smtplib.SMTP('localhost') as s:
        s.send_message(msg)

if __name__ == "__main__":
    send_alert(check_keys())
