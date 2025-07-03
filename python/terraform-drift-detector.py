import subprocess
import datetime

def check_drift():
    result = subprocess.run(['terraform', 'plan', '-detailed-exitcode'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    code = result.returncode
    output = result.stdout.decode()
    if code == 2:
        with open('drift_log.txt', 'a') as f:
            f.write(f"{datetime.datetime.now()} - Drift detected\n{output}\n")
        print("Drift detected! Check drift_log.txt.")
    elif code == 0:
        print("No drift detected.")
    else:
        print("Error running terraform plan")

if __name__ == "__main__":
    check_drift()
