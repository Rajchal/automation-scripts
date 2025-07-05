import subprocess
import datetime

SERVICE = "nginx"
THRESHOLD = 5  # restarts
INTERVAL = 3600  # seconds (1 hour)

def get_restart_times(service):
    output = subprocess.check_output(["journalctl", "-u", service, "--since", "1 hour ago", "--grep", "Starting"]).decode()
    times = [line.split()[2] for line in output.splitlines() if "Starting" in line]
    return times

def main():
    times = get_restart_times(SERVICE)
    if len(times) > THRESHOLD:
        print(f"Warning: {SERVICE} restarted {len(times)} times in the last hour!")

if __name__ == "__main__":
    main()
