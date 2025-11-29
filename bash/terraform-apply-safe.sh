#!/usr/bin/env bash
set -euo pipefail

# Run terraform fmt, validate, plan and optionally apply with confirmation.
# Usage: terraform-apply-safe.sh [--dir PATH] [--auto-approve]

usage(){
  cat <<EOF
Usage: $0 [--dir PATH] [--auto-approve]

Runs terraform fmt, validate, plan, and prompts to apply. Defaults to dry-run (no apply).
Options:
  --dir PATH        Directory with terraform files (default: current directory)
  --auto-approve    Pass auto-approve to terraform apply (use with caution)
  -h                Help
EOF
}

DIR="."
AUTO_APPROVE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2;;
    --auto-approve) AUTO_APPROVE=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown $1"; usage; exit 2;;
  esac
done

if ! command -v terraform >/dev/null 2>&1; then
  echo "terraform not found in PATH"; exit 3
fi

echo "Running in directory: $DIR"
pushd "$DIR" >/dev/null

echo "1) Formatting..."
terraform fmt -recursive

echo "2) Initializing (if needed)..."
terraform init -input=false

echo "3) Validating..."
terraform validate

echo "4) Planning..."
planfile="tfplan-$(date +%s)"
terraform plan -out="$planfile"

echo "Plan saved to $planfile"

if [[ "$AUTO_APPROVE" == true ]]; then
  echo "Auto-approve: applying plan"
  terraform apply -input=false -auto-approve "$planfile"
else
  read -p "Apply plan now? (y/N): " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    terraform apply -input=false "$planfile"
  else
    echo "Skipping apply. To apply later: terraform apply $planfile"
  fi
fi

popd >/dev/null
echo "Done."
