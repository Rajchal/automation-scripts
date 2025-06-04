import psutil
import time

# Kill processes exceeding CPU or memory thresholds

CPU_THRESHOLD = 80  # percent
MEM_THRESHOLD = 500 * 1024 * 1024  # 500 MB

def kill_heavy_processes():
    print("Scanning for heavy resource-consuming processes...")
    for proc in psutil.process_iter(['pid', 'name', 'cpu_percent', 'memory_info']):
        try:
            cpu = proc.info['cpu_percent']
            mem = proc.info['memory_info'].rss
            if cpu > CPU_THRESHOLD or mem > MEM_THRESHOLD:
                print(f"Killing {proc.info['name']} (PID {proc.info['pid']}): CPU {cpu}%, Memory {mem/(1024*1024):.2f}MB")
                proc.kill()
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue

if __name__ == "__main__":
    # Call psutil.cpu_percent once to initialize
    psutil.cpu_percent(interval=None)
    time.sleep(1)
    kill_heavy_processes()
