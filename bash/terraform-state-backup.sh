#!/usr/bin/env bash
set -euo pipefail

# terraform-state-backup.sh
# Backup Terraform state files to S3 with versioning and encryption.
# Supports local and remote state backends, with optional restoration.
# Dry-run by default; use --no-dry-run to backup state files.

usage(){
  cat <<EOF
Usage: $0 --s3-bucket BUCKET [--state-file PATH] [--prefix PREFIX] [--restore VERSION] [--no-dry-run]

Options:
  --s3-bucket BUCKET       S3 bucket for state backups (required)
  --state-file PATH        Path to terraform.tfstate file (default: ./terraform.tfstate)
  --prefix PREFIX          S3 key prefix for backups (default: terraform-backups)
  --workspace NAME         Terraform workspace name (default: default)
  --restore VERSION        Restore specific version from S3 (version-id)
  --region REGION          AWS region for S3 bucket
  --no-dry-run             Execute backup/restore (default: dry-run)
  -h, --help               Show this help

Examples:
  # Dry-run: show what would be backed up
  bash/terraform-state-backup.sh --s3-bucket my-terraform-states

  # Backup current state
  bash/terraform-state-backup.sh --s3-bucket my-terraform-states --no-dry-run

  # Backup with custom path and prefix
  bash/terraform-state-backup.sh --s3-bucket my-bucket --state-file /path/to/terraform.tfstate --prefix prod/backups --no-dry-run

  # Restore specific version
  bash/terraform-state-backup.sh --s3-bucket my-bucket --restore versionId123 --no-dry-run

  # Daily backup via cron
  0 2 * * * cd /infra && /path/to/terraform-state-backup.sh --s3-bucket states --no-dry-run

EOF
}

S3_BUCKET=""
STATE_FILE="./terraform.tfstate"
PREFIX="terraform-backups"
WORKSPACE="default"
RESTORE_VERSION=""
REGION=""
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --s3-bucket) S3_BUCKET="$2"; shift 2;;
    --state-file) STATE_FILE="$2"; shift 2;;
    --prefix) PREFIX="$2"; shift 2;;
    --workspace) WORKSPACE="$2"; shift 2;;
    --restore) RESTORE_VERSION="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if [[ -z "$S3_BUCKET" ]]; then
  echo "--s3-bucket is required"; usage; exit 2
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI required"; exit 3
fi

AWS=(aws s3api)
if [[ -n "$REGION" ]]; then
  AWS+=(--region "$REGION")
fi

echo "Terraform State Backup: bucket=$S3_BUCKET state-file=$STATE_FILE workspace=$WORKSPACE dry-run=$DRY_RUN"

# Generate backup key
timestamp=$(date -u +%Y%m%d-%H%M%S)
s3_key="${PREFIX}/${WORKSPACE}/terraform.tfstate.${timestamp}"

if [[ -n "$RESTORE_VERSION" ]]; then
  # RESTORE MODE
  echo ""
  echo "=== RESTORE MODE ==="
  
  restore_key="${PREFIX}/${WORKSPACE}/terraform.tfstate"
  local_backup="${STATE_FILE}.backup-$(date +%s)"
  
  if [[ "$DRY_RUN" == true ]]; then
    echo "DRY RUN: would restore version $RESTORE_VERSION from s3://$S3_BUCKET/$restore_key"
    echo "DRY RUN: would backup current state to $local_backup"
  else
    # Backup current state first
    if [[ -f "$STATE_FILE" ]]; then
      echo "Backing up current state to: $local_backup"
      cp "$STATE_FILE" "$local_backup"
    fi
    
    echo "Restoring version $RESTORE_VERSION from S3..."
    "${AWS[@]}" get-object \
      --bucket "$S3_BUCKET" \
      --key "$restore_key" \
      --version-id "$RESTORE_VERSION" \
      "$STATE_FILE" 2>/dev/null || {
        echo "Failed to restore state"
        exit 1
      }
    
    echo "State restored successfully to: $STATE_FILE"
    echo "Previous state backed up to: $local_backup"
  fi
  
  exit 0
fi

# BACKUP MODE
if [[ ! -f "$STATE_FILE" ]]; then
  echo "State file not found: $STATE_FILE"
  exit 1
fi

# Check if state file is valid JSON
if ! jq empty "$STATE_FILE" 2>/dev/null; then
  echo "Invalid state file (not valid JSON): $STATE_FILE"
  exit 1
fi

# Get state file info
state_size=$(stat -f%z "$STATE_FILE" 2>/dev/null || stat -c%s "$STATE_FILE" 2>/dev/null)
state_checksum=$(md5sum "$STATE_FILE" 2>/dev/null | awk '{print $1}' || md5 -q "$STATE_FILE" 2>/dev/null)
terraform_version=$(jq -r '.terraform_version // "unknown"' "$STATE_FILE" 2>/dev/null)

echo ""
echo "State file info:"
echo "  Path: $STATE_FILE"
echo "  Size: $state_size bytes"
echo "  MD5: $state_checksum"
echo "  Terraform version: $terraform_version"

if [[ "$DRY_RUN" == true ]]; then
  echo ""
  echo "DRY RUN: would upload to s3://$S3_BUCKET/$s3_key"
  echo "DRY RUN: would use server-side encryption (AES256)"
  exit 0
fi

# Check if bucket exists and has versioning enabled
echo ""
echo "Checking S3 bucket configuration..."
versioning_status=$("${AWS[@]}" get-bucket-versioning --bucket "$S3_BUCKET" --query 'Status' --output text 2>/dev/null || echo "")

if [[ "$versioning_status" != "Enabled" ]]; then
  echo "⚠️  Warning: Versioning is not enabled on bucket $S3_BUCKET"
  echo "   Consider enabling versioning for better state history management"
fi

# Upload state to S3
echo "Uploading state to S3..."
aws s3 cp "$STATE_FILE" "s3://$S3_BUCKET/$s3_key" \
  --server-side-encryption AES256 \
  --metadata "terraform-version=$terraform_version,workspace=$WORKSPACE,backup-date=$timestamp" \
  2>/dev/null || {
    echo "Failed to upload state to S3"
    exit 1
  }

# Also maintain a "latest" copy for easy restoration
latest_key="${PREFIX}/${WORKSPACE}/terraform.tfstate"
aws s3 cp "$STATE_FILE" "s3://$S3_BUCKET/$latest_key" \
  --server-side-encryption AES256 \
  --metadata "terraform-version=$terraform_version,workspace=$WORKSPACE,backup-date=$timestamp" \
  2>/dev/null || echo "Warning: Failed to update latest state"

echo ""
echo "✓ State backed up successfully"
echo "  Timestamped: s3://$S3_BUCKET/$s3_key"
echo "  Latest: s3://$S3_BUCKET/$latest_key"

# List recent backups
echo ""
echo "Recent backups:"
aws s3 ls "s3://$S3_BUCKET/${PREFIX}/${WORKSPACE}/" 2>/dev/null | tail -5 || echo "  Unable to list backups"

echo ""
echo "Done."
