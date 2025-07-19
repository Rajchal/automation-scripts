import os

THRESHOLD = 1000

def main():
    for pid in os.listdir('/proc'):
        if pid.isdigit():
            try:
                fd_count = len(os.listdir(f'/proc/{pid}/fd'))
                if fd_count > THRESHOLD:
                    with open(f'/proc/{pid}/comm') as f:
                        name = f.read().strip()
                    print(f"Process {pid} ({name}) uses {fd_count} file descriptors")
            except Exception:
                continue

if __name__ == "__main__":
    main()