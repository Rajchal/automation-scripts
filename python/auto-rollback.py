import time
import subprocess

LOG_FILE = "/var/log/deploy.log"

def monitor_logs():
    print("Monitoring deployment logs...")

    # Open the log file and monitor it
    with open(LOG_FILE, "r") as log:
        # Move to the end of the file
        log.seek(0, os.SEEK_END)

        while True:
            line = log.readline()
            if "deployment failed" in line:
                print("Deployment failed! Initiating rollback...")
                subprocess.run(["/path/to/rollback.sh"])
                break
            time.sleep(1)

if __name__ == "__main__":
    monitor_logs()
