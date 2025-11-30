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
| `aws-rds-snapshot-public-auditor.py` | Detects public RDS (and Aurora cluster) snapshots; can revoke public restore permission. |
| `aws-sns-unused-topic-auditor.py` | Finds unused SNS topics via metrics; optional tag or safe delete when no subscriptions. |
| `aws-config-recorder-status-auditor.py` | Audits AWS Config recorder/channel status; can start stopped recorders. |
| `aws-dynamodb-usage-auditor.py` | Flags under-utilized DynamoDB tables (PROVISIONED or PAY_PER_REQUEST); optional tagging. |
| `aws-secretsmanager-stale-secret-auditor.py` | Flags stale/unrotated Secrets Manager secrets; optional tag or schedule-delete. |
| `aws-route53-hosted-zone-orphaned-auditor.py` | Finds hosted zones with only SOA/NS or private zones without VPCs; optional tagging. |
| `aws-iam-role-last-used-auditor.py` | Flags IAM roles not used in N days; optional tagging and CI-friendly mode. |
| `aws-opensearch-idle-domain-auditor.py` | Flags low-activity OpenSearch/Elasticsearch domains (CloudWatch metrics); optional tagging & CI mode. |
| `aws-efs-unused-filesystem-auditor.py` | Flags unused/low-activity EFS file systems (mount targets + metrics); optional tagging. |
| `aws-elasticache-idle-auditor.py` | Detects idle ElastiCache replication-groups / cache clusters via CurrConnections & CPU; optional tagging. |
| `aws-ec2-idle-instance-auditor.py` | Identifies low CPU + low network EC2 instances; optional tag or stop with safety caps & CI exit. |
| `aws-elasticache-snapshot-retention-auditor.py` | Flags low automatic snapshot retention & old manual Redis snapshots; optional tagging & CI exit. |
| `aws-rds-idle-instance-auditor.py` | Flags low-activity RDS DB instances and Aurora clusters (CPU, connections, IOPS); optional tagging & CI exit. |
| `aws-ecr-repository-empty-auditor.py` | Detects empty or stale ECR repositories; optional tagging and safe delete (empty-only) with caps & CI exit. |
| `aws-s3-unused-bucket-auditor.py` | Flags empty or stale S3 buckets (object count + last modified age); optional tagging & safe empty delete with caps & CI exit. |
| `k8s-pod-restart-spike-auditor.py` | Detects pods with high container restart counts in recent age window; optional annotation & CI exit. |

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


### New Bash Helpers (usage)

- **`bash/aws-ecr-image-pruner.sh`**: dry-run by default; deletes ECR images older than X days.

    Basic example (dry-run):

    ```bash
    bash/bash/aws-ecr-image-pruner.sh -r my-repo -d 30 --dry-run
    ```

    To actually delete, pass `--no-dry-run` (use with caution):

    ```bash
    bash/aws-ecr-image-pruner.sh -r my-repo -d 30 --no-dry-run
    ```

     - **`bash/aws-cloudwatch-alarms-check.sh`**: list alarms in `ALARM` state and optionally publish a summary to an SNS topic.

      Basic example (dry-run):

      ```bash
      bash/aws-cloudwatch-alarms-check.sh --dry-run
      ```

      To publish to SNS (dry-run by default), pass an SNS topic ARN and `--no-dry-run`:

      ```bash
      bash/aws-cloudwatch-alarms-check.sh --sns-topic arn:aws:sns:us-east-1:123456789012:my-topic --no-dry-run
      ```

     - **`bash/ecs-service-redeploy.sh`**: force a new deployment of an ECS service (supports EC2 & Fargate). Dry-run prints the update command.

      Basic example (dry-run):

      ```bash
      bash/ecs-service-redeploy.sh -c my-cluster -s my-service --dry-run
      ```

      To perform the update (force new deployment):

      ```bash
      bash/ecs-service-redeploy.sh -c my-cluster -s my-service --no-dry-run
      ```

     - **`bash/terraform-apply-safe.sh`**: runs `terraform fmt`, `init`, `validate`, and `plan` then prompts to apply. Useful as a safe wrapper before applying changes.

      Basic example:

      ```bash
      bash/terraform-apply-safe.sh --dir infra
      ```

      To auto-approve the apply (use with caution):

      ```bash
      bash/terraform-apply-safe.sh --dir infra --auto-approve
      ```

     - **`bash/kube-namespace-cleaner.sh`**: safely delete completed jobs and evicted pods in a namespace older than X days (dry-run by default).

      Basic example (dry-run):

      ```bash
      bash/kube-namespace-cleaner.sh -n my-namespace -d 7 --dry-run
      ```

      To actually perform deletions (requires `kubectl` + appropriate permissions):

      ```bash
      bash/kube-namespace-cleaner.sh -n my-namespace -d 7 --no-dry-run
      ```

     - **`bash/aws-iam-unused-keys-report.sh`**: find IAM access keys that appear unused (based on last-used date) and optionally deactivate them.

      Basic example (dry-run):

      ```bash
      bash/aws-iam-unused-keys-report.sh --all --age 90
      ```

      To deactivate candidates (use with caution):

      ```bash
      bash/aws-iam-unused-keys-report.sh --all --age 180 --deactivate --no-dry-run
      ```

     - **`bash/aws-s3-lifecycle-apply.sh`**: detect S3 buckets missing lifecycle expiration/transition rules and propose a safe lifecycle. Dry-run by default; use `--apply --no-dry-run` to put the lifecycle policy.

      Basic example (dry-run):

      ```bash
      bash/aws-s3-lifecycle-apply.sh --age-days 365 --transition-days 30
      ```

      To apply the suggested lifecycle to detected buckets:

      ```bash
      bash/aws-s3-lifecycle-apply.sh --age-days 365 --transition-days 30 --apply --no-dry-run
      ```

     - **`bash/aws-ec2-idle-instance-auditor.sh`**: find running EC2 instances with low average CPU over a period (uses CloudWatch). Dry-run by default; can stop instances with `--stop --no-dry-run`.

      Basic example (dry-run):

      ```bash
      bash/aws-ec2-idle-instance-auditor.sh --days 7 --cpu-threshold 3
      ```

      To stop candidates (use with caution):

      ```bash
      bash/aws-ec2-idle-instance-auditor.sh --days 7 --cpu-threshold 3 --stop --no-dry-run
      ```


## Disclaimer

Use these scripts at your own risk. Test thoroughly before deploying in production environments. Please contact me if there is any issue using mail.
