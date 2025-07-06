import subprocess
from datetime import datetime, timedelta

AGE_DAYS = 30

def main():
    out = subprocess.check_output(['git', 'for-each-ref', '--format=%(refname:short) %(committerdate:iso8601)', 'refs/heads/'])
    now = datetime.now()
    for line in out.decode().splitlines():
        branch, date = line.split(' ', 1)
        commit_date = datetime.fromisoformat(date)
        if (now - commit_date).days > AGE_DAYS:
            print(f"Branch '{branch}' is {(now-commit_date).days} days old.")

if __name__ == "__main__":
    main()
