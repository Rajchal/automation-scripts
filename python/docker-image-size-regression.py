import subprocess

IMAGE_NAME = "your-image"
TAG_OLD = "previous"
TAG_NEW = "latest"
THRESHOLD_MB = 10

def get_size(tag):
    out = subprocess.check_output(['docker', 'image', 'inspect', f"{IMAGE_NAME}:{tag}", '--format', '{{.Size}}'])
    return int(out.strip()) / (1024 * 1024)

def main():
    size_old = get_size(TAG_OLD)
    size_new = get_size(TAG_NEW)
    if size_new - size_old > THRESHOLD_MB:
        print(f"WARNING: {IMAGE_NAME} grew by {size_new - size_old:.1f} MB ({size_old:.1f} -> {size_new:.1f})")

if __name__ == "__main__":
    main()
