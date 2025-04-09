import os
import time

def clean_logs(directory, days_old=7):
    now = time.time()
    for filename in os.listdir(directory):
        file_path = os.path.join(directory, filename)
        if os.stat(file_path).st_mtime < now - days_old * 86400:
            os.remove(file_path)
            print(f"Deleted: {file_path}")clean_logs("/var/logs")
