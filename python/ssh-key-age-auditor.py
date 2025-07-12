import os
import datetime

THRESHOLD_DAYS = 90

def check_user_keys(user_home):
    ak_path = os.path.join(user_home, ".ssh", "authorized_keys")
    if not os.path.exists(ak_path):
        return
    mtime = datetime.datetime.fromtimestamp(os.path.getmtime(ak_path))
    age = (datetime.datetime.now() - mtime).days
    if age > THRESHOLD_DAYS:
        print(f"{ak_path} last modified {age} days ago")

def main():
    for user in os.listdir("/home"):
        check_user_keys(os.path.join("/home", user))

if __name__ == "__main__":
    main()
