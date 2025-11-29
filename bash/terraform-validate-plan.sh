#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 --dir PATH [--out planfile] [--var-file file] [--auto-approve]

Runs terraform fmt (check), terraform validate, and terraform plan in the given directory.

Options:
  --dir PATH       terraform configuration directory (required)
  --out FILE       plan output file (default: plan.tfplan)
  --var-file FILE  pass a -var-file to terraform plan
  --auto-approve    skip interactive approval for plan (just writes plan)

Example: $0 --dir infra/ --out myplan.tfplan --var-file prod.tfvars
EOF
}

DIR=""
OUT="plan.tfplan"
VARFILE=""
AUTO_APPROVE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --var-file) VARFILE="$2"; shift 2;;
    --auto-approve) AUTO_APPROVE=1; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if [[ -z "$DIR" ]]; then echo "--dir is required"; usage; exit 2; fi
if [[ ! -d "$DIR" ]]; then echo "Directory $DIR does not exist"; exit 2; fi

pushd "$DIR" >/dev/null

echo "Running terraform fmt (check)"
terraform fmt -check

echo "Running terraform init -backend=false"
terraform init -backend=false

echo "Running terraform validate"
terraform validate

PLAN_CMD=(terraform plan -out "$OUT")
if [[ -n "$VARFILE" ]]; then PLAN_CMD+=( -var-file="$VARFILE" ); fi
if (( AUTO_APPROVE )); then PLAN_CMD+=( -input=false ); fi

echo "Running: ${PLAN_CMD[*]}"
"${PLAN_CMD[@]}"

echo "Plan written to $OUT"
popd >/dev/null
