import psutil

def main():
    for proc in psutil.process_iter(['pid', 'ppid', 'status', 'name']):
        if proc.info['status'] == psutil.STATUS_ZOMBIE:
            print(f"Zombie process: PID {proc.info['pid']} (Parent PID {proc.info['ppid']}) Name: {proc.info['name']}")

if __name__ == "__main__":
    main()