import boto3
import json

BASELINE_FILE = "instance_type_baseline.json"
ec2 = boto3.client('ec2')

def load_baseline():
    try:
        with open(BASELINE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}

def save_baseline(baseline):
    with open(BASELINE_FILE, 'w') as f:
        json.dump(baseline, f)

def main():
    baseline = load_baseline()
    changed = False
    reservations = ec2.describe_instances()['Reservations']
    current = {}
    for res in reservations:
        for inst in res['Instances']:
            iid = inst['InstanceId']
            itype = inst['InstanceType']
            current[iid] = itype
            if baseline.get(iid) and baseline[iid] != itype:
                print(f"Instance {iid} changed type from {baseline[iid]} to {itype}")
                changed = True
    save_baseline(current)
    if not changed:
        print("No instance type changes detected.")

if __name__ == "__main__":
    main()
