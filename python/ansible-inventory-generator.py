import boto3

# Generate an Ansible inventory file from AWS EC2 instances

def generate_inventory(region='us-east-1'):
    ec2 = boto3.client('ec2', region_name=region)
    res = ec2.describe_instances()
    hosts = []
    for r in res['Reservations']:
        for inst in r['Instances']:
            if inst.get('State', {}).get('Name') == 'running':
                hosts.append(inst['PublicIpAddress'])
    with open('inventory.ini', 'w') as f:
        f.write('[aws-hosts]\n')
        for h in hosts:
            f.write(f"{h}\n")
    print("Inventory generated: inventory.ini")

if __name__ == "__main__":
    generate_inventory()
