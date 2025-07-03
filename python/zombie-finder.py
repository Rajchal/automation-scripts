import subprocess
import smtplib
from email.mime.text import MIMEText

ALERT_EMAIL = "admin@example.com"

def find_zombies():
    result = subprocess.run(['ps', 'axo', 'pid,stat,cmd'], stdout=subprocess.PIPE)
    lines = result.stdout.decode().splitlines()
    zombies = [l for l in lines if 'Z' in l.split()[1]]
    return zombies

def send_alert(zombies):
    if not zombies:
        return
    msg = MIMEText('\n'.join(zombies))
    msg['Subject'] = 'Zombie Process Alert'
    msg['From'] = ALERT_EMAIL
    msg['To'] = ALERT_EMAIL
    with smtplib.SMTP('localhost') as s:
        s.send_message(msg)

if __name__ == "__main__":
    zombies = find_zombies()
    send_alert(zombies)
