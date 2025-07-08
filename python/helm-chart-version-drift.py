import subprocess
import yaml

DESIRED_FILE = "desired_helm_versions.yaml"

def get_deployed_versions():
    out = subprocess.check_output(['helm', 'list', '-A', '-o', 'yaml'])
    return {r['name']: r['chart'].split('-')[-1] for r in yaml.safe_load(out)}

def get_desired_versions():
    with open(DESIRED_FILE) as f:
        return yaml.safe_load(f)

def main():
    deployed = get_deployed_versions()
    desired = get_desired_versions()
    for chart, version in desired.items():
        if deployed.get(chart) != version:
            print(f"Drift: {chart} deployed={deployed.get(chart)}, desired={version}")

if __name__ == "__main__":
    main()
