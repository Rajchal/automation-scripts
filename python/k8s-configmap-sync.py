import subprocess

# Sync a ConfigMap from one namespace to another in Kubernetes

def sync_configmap(source_ns, target_ns, configmap_name):
    print(f"Exporting ConfigMap '{configmap_name}' from '{source_ns}'...")
    dump = subprocess.check_output([
        "kubectl", "get", "configmap", configmap_name, "-n", source_ns, "-o", "yaml"
    ])
    with open("/tmp/cm.yaml", "wb") as f:
        f.write(dump)
    print(f"Applying ConfigMap to '{target_ns}'...")
    subprocess.run([
        "kubectl", "apply", "-n", target_ns, "-f", "/tmp/cm.yaml"
    ])
    print("Sync complete.")

if __name__ == "__main__":
    s = input("Source namespace: ")
    t = input("Target namespace: ")
    c = input("ConfigMap name: ")
    sync_configmap(s, t, c)
