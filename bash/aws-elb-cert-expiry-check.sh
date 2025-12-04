#!/usr/bin/env bash
set -euo pipefail

# aws-elb-cert-expiry-check.sh
# Check ELB/ALB/NLB listener certificates for expiry.
# Reports certificates expiring within N days with optional alerting.
# Dry-run by default (reports only).

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--days N] [--only-expired] [--alert-email EMAIL] [--no-dry-run]

Options:
  --region REGION        AWS region (uses AWS_DEFAULT_REGION if unset)
  --days N               Alert on certs expiring within N days (default: 30)
  --only-expired         Only report already-expired certs
  --alert-email EMAIL    Send alert email (SNS topic ARN or email) - requires setup
  --no-dry-run           Apply alerting (if --alert-email provided)
  -h, --help             Show this help

Examples:
  # Dry-run: check for certs expiring within 30 days
  bash/aws-elb-cert-expiry-check.sh

  # Check for certs expiring within 90 days
  bash/aws-elb-cert-expiry-check.sh --days 90

  # Only report expired certs
  bash/aws-elb-cert-expiry-check.sh --only-expired

EOF
}

REGION=""
DAYS=30
ONLY_EXPIRED=false
ALERT_EMAIL=""
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --only-expired) ONLY_EXPIRED=true; shift;;
    --alert-email) ALERT_EMAIL="$2"; shift 2;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI required"; exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq required"; exit 3
fi

ELB=(aws elbv2)
if [[ -n "$REGION" ]]; then
  ELB+=(--region "$REGION")
fi

echo "ELB cert expiry check: days=$DAYS only-expired=$ONLY_EXPIRED alert-email=${ALERT_EMAIL:-none} dry-run=$DRY_RUN"

now_epoch=$(date +%s)
alert_threshold=$((now_epoch + DAYS*24*3600))

# Describe all load balancers
lbs_json=$("${ELB[@]}" describe-load-balancers --output json 2>/dev/null || echo '{}')
mapfile -t lbs < <(echo "$lbs_json" | jq -c '.LoadBalancers[]?')

if [[ ${#lbs[@]} -eq 0 ]]; then
  echo "No load balancers found."; exit 0
fi

declare -a alerts

for lb in "${lbs[@]}"; do
  lb_arn=$(echo "$lb" | jq -r '.LoadBalancerArn')
  lb_name=$(echo "$lb" | jq -r '.LoadBalancerName')
  lb_type=$(echo "$lb" | jq -r '.Type')

  echo "\nLoad Balancer: $lb_name (type=$lb_type)"

  # Describe listeners for this LB
  listeners_json=$("${ELB[@]}" describe-listeners --load-balancer-arn "$lb_arn" --output json 2>/dev/null || echo '{}')
  mapfile -t listeners < <(echo "$listeners_json" | jq -c '.Listeners[]?')

  if [[ ${#listeners[@]} -eq 0 ]]; then
    echo "  No listeners found."; continue
  fi

  for listener in "${listeners[@]}"; do
    port=$(echo "$listener" | jq -r '.Port')
    protocol=$(echo "$listener" | jq -r '.Protocol')

    # Check for certificates in DefaultActions
    mapfile -t certs < <(echo "$listener" | jq -r '.Certificates[]? | .CertificateArn' 2>/dev/null || echo "")

    if [[ ${#certs[@]} -eq 0 ]]; then
      continue
    fi

    for cert_arn in "${certs[@]}"; do
      if [[ -z "$cert_arn" || "$cert_arn" == "null" ]]; then
        continue
      fi

      # Describe certificate
      cert_json=$("${ELB[@]}" describe-ssl-certificates --certificate-arns "$cert_arn" --output json 2>/dev/null || echo '{}')
      cert_details=$(echo "$cert_json" | jq -c '.ServerCertificateMetadata[0]? // empty')

      if [[ -z "$cert_details" ]]; then
        continue
      fi

      cert_name=$(echo "$cert_details" | jq -r '.ServerCertificateName // empty')
      expiry=$(echo "$cert_details" | jq -r '.Expiration // empty')

      if [[ -z "$expiry" ]]; then
        continue
      fi

      expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)

      if [[ $expiry_epoch -le 0 ]]; then
        continue
      fi

      days_until=$(( (expiry_epoch - now_epoch) / 86400 ))

      if [[ $days_until -lt 0 ]]; then
        status="EXPIRED"
      elif [[ $expiry_epoch -le $alert_threshold ]]; then
        status="EXPIRING_SOON"
      else
        status="OK"
        continue
      fi

      if [[ "$ONLY_EXPIRED" == true && "$status" != "EXPIRED" ]]; then
        continue
      fi

      echo "  Listener $protocol:$port cert=$cert_name status=$status expiry=$expiry days_until=$days_until"
      alerts+=("$lb_name|$protocol:$port|$cert_name|$status|$expiry|$days_until")
    done
  done
done

if [[ ${#alerts[@]} -eq 0 ]]; then
  echo "\nNo certificate expiry issues found."; exit 0
fi

echo "\n=== Alert Summary ==="
for alert in "${alerts[@]}"; do
  IFS='|' read -r lb listener cert status exp days <<< "$alert"
  echo "ALERT: LB=$lb Listener=$listener Cert=$cert Status=$status Expiry=$exp DaysUntil=$days"
done

if [[ -n "$ALERT_EMAIL" && "$DRY_RUN" == false ]]; then
  echo "\nSending alerts to $ALERT_EMAIL..."
  # This is a placeholder; actual SNS integration would go here
  echo "Alert notification would be sent (SNS integration not yet implemented)"
fi

echo "\nDone."
