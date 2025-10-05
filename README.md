# Small Automation Scripts for DevOps

This repository contains a collection of essential automation scripts written in Bash and Python, designed to streamline and simplify various DevOps tasks. These scripts are lightweight, efficient, and tailored to address common challenges faced in DevOps workflows.

## Features

- **Automation**: Scripts to automate repetitive tasks, saving time and reducing human error.
- **Flexibility**: Easily customizable to fit specific project requirements.
- **Cross-Platform**: Compatible with most Unix-based systems.
- **Scalability**: Suitable for small to large-scale DevOps operations.

## Scripts Overview

1. **Infrastructure Management**: Automate provisioning, configuration, and monitoring of servers.
2. **CI/CD Pipelines**: Scripts to enhance continuous integration and deployment processes.
3. **Log Management**: Tools for parsing, analyzing, and managing logs.
4. **Backup and Recovery**: Automate backup creation and restoration.
5. **Miscellaneous Utilities**: Handy scripts for everyday DevOps tasks.

### Recently Added (Highlights)

Python automation additions focused on Kubernetes, AWS, Docker, Git, and security hygiene:

| Script | Purpose |
|--------|---------|
| `k8s-unused-configmap-secret-auditor.py` | Lists ConfigMaps/Secrets not referenced by any Pod. |
| `k8s-stuck-finalizer-cleaner.py` | Detects terminating resources stuck on finalizers (read‑only suggestions). |
| `k8s-node-cordon-drift-detector.py` | Flags nodes cordoned too long without reason annotation. |
| `aws-ebs-low-iops-detector.py` | Heuristic saturation / low baseline check for EBS volumes. |
| `k8s-unused-ingress-detector.py` | Ingress objects with no live service backends. |
| `docker-build-cache-pruner.py` | Dry‑run & prune Docker/buildx build cache by age. |
| `systemd-service-start-latency-profiler.py` | Journal-based service startup latency stats. |
| `tls-cipher-suite-auditor.py` | Openssl-based cipher/protocol & weak suite scan. |
| `k8s-image-registry-compliance.py` | Enforces allowed image registry prefixes / digest policy. |
| `git-large-file-new-commit-blocker.py` | Blocks new large blobs in commit range (CI friendly). |
| `aws-security-group-unused-ingress-auditor.py` | Finds unattached / inert security groups & rules. |
| `k8s-pdb-gap-detector.py` | Workloads missing or with ineffective PodDisruptionBudgets. |
| `docker-layer-size-analyzer.py` | Shows per-layer sizes; flags oversized layers. |
| `expired-acm-cert-detector.py` | Multi-region ACM certificate expiry reporting. |
| `aws-eni-unattached-auditor.py` | Finds unattached ENIs (status=available); optional deletion with caps. |
| `aws-nat-gateway-idle-auditor.py` | Flags potentially idle NAT Gateways using CloudWatch metrics; optional tagging. |
| `aws-kms-rotation-auditor.py` | Audits KMS CMKs for rotation; can enable rotation for eligible keys. |
| `aws-elbv2-idle-auditor.py` | Flags potentially idle ALB/NLB via CloudWatch metrics; optional tagging. |
| `aws-s3-lifecycle-gap-auditor.py` | Detects S3 lifecycle gaps and can apply a safe default rule template. |
| `aws-sqs-unused-queue-auditor.py` | Finds unused SQS queues via metrics; optional tag or safe delete of empty non-DLQs. |

### Quick Usage Examples

```bash
# Kubernetes audits
python3 python/k8s-unused-configmap-secret-auditor.py
python3 python/k8s-pdb-gap-detector.py --json

# AWS checks
python3 python/aws-ebs-low-iops-detector.py --region us-east-1
python3 python/expired-acm-cert-detector.py --regions us-east-1,us-west-2 --days 20

# Docker hygiene
python3 python/docker-build-cache-pruner.py --older-than 12h --apply
python3 python/docker-layer-size-analyzer.py --image alpine:3.19

# Git large file guard (fail if >5MB new blobs)
python3 python/git-large-file-new-commit-blocker.py --threshold-mb 5

# TLS cipher scan
python3 python/tls-cipher-suite-auditor.py --targets example.com:443 --full --json
```

### Python Dependencies (on-demand)

Install dependencies via requirements file (recommended):

```bash
pip install -r requirements.txt
```

Or install ad-hoc for specific scripts:

```bash
pip install kubernetes boto3
```

Some scripts rely on system tools:
- `openssl` (cipher auditor)
- `docker` CLI + buildx plugin (cache pruner, layer analyzer)
- `journalctl` / systemd (latency profiler)

### CI Integration Hints

- Fail pipeline on drift / violations:
    - `git-large-file-new-commit-blocker.py` (exit 2 if large files)
    - `docker-layer-size-analyzer.py` (exit 2 if oversized layers)
    - `k8s-image-registry-compliance.py` (non-zero on API error only; wrap with grep if needed)

### Safe Use Notes

- Auditors are read-only; any printed `kubectl` / `aws` delete commands are suggestions—review manually.
- For cluster scripts, ensure `KUBECONFIG` or in-cluster service account perms are appropriate (list/read only).

---

## Getting Started

1. Clone the repository:
    ```bash
    git clone https://github.com/Rajchal/automation-scripts.git
    cd automation-scripts
    ```

2. Run the scripts:
    ```bash
    ./script-name.sh
    ```
    or
    ```bash
    python3 script_name.py
    ```

## Contributing

Contributions are welcome! Feel free to submit issues or pull requests to improve the scripts or add new ones.


## Disclaimer

Use these scripts at your own risk. Test thoroughly before deploying in production environments. Please contact me if there is any issue using mail.
