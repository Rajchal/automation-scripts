#!/usr/bin/env bash
set -euo pipefail

# Audit OpenSearch/Elasticsearch domains for low CPU activity over a lookback window.
# Dry-run by default. Tagging requires --tag --no-dry-run. Uses CloudWatch metric `CPUUtilization`.

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--days N] [--cpu-threshold PERCENT] [--tag] [--no-dry-run]

Options:
  --region REGION        AWS region (uses AWS_DEFAULT_REGION if unset)
  --days N               Lookback window in days for CloudWatch metrics (default: 14)
  --cpu-threshold PCT    Consider idle if avg CPU <= PCT (default: 5)
  --tag                  Tag candidate domains with Key=idle_candidate,Value=true (best-effort)
  --dry-run              Default; only print actions
  --no-dry-run           Apply tagging when requested
  -h, --help             Show this help

Example (dry-run):
  bash/aws-opensearch-idle-domain-auditor.sh --days 14 --cpu-threshold 5

To tag candidates (best-effort):
  bash/aws-opensearch-idle-domain-auditor.sh --tag --no-dry-run

EOF
}

REGION=""
DAYS=14
CPU_THRESHOLD=5
DO_TAG=false
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --cpu-threshold) CPU_THRESHOLD="$2"; shift 2;;
    --tag) DO_TAG=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
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

OS=(aws opensearch)
CW=(aws cloudwatch)
if [[ -n "$REGION" ]]; then
  OS+=(--region "$REGION")
  CW+=(--region "$REGION")
fi

echo "OpenSearch auditor: days=$DAYS cpu_th=$CPU_THRESHOLD% tag=$DO_TAG dry-run=$DRY_RUN"

end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_time=$(date -u -d "-$DAYS days" +%Y-%m-%dT%H:%M:%SZ)

echo "Listing OpenSearch domains..."
domains_json=$(${OS[*]} list-domain-names --output json 2>/dev/null || echo '{}')
mapfile -t domains < <(echo "$domains_json" | jq -r '.DomainNames[]?.DomainName')

if [[ ${#domains[@]} -eq 0 ]]; then
  # fallback to older `es` service name
  domains_json=$(aws es list-domain-names --output json 2>/dev/null || echo '{}')
  mapfile -t domains < <(echo "$domains_json" | jq -r '.DomainNames[]?.DomainName')
fi

if [[ ${#domains[@]} -eq 0 ]]; then
  echo "No OpenSearch/Elasticsearch domains found."; exit 0
fi

declare -a candidates

for d in "${domains[@]}"; do
  echo "Checking domain $d"
  resp=$(${CW[*]} get-metric-statistics --namespace AWS/ES --metric-name CPUUtilization --statistics Average --period 3600 --start-time "$start_time" --end-time "$end_time" --dimensions Name=DomainName,Value=$d --output json 2>/dev/null || echo '{}')
  avg=$(echo "$resp" | jq -r '[.Datapoints[].Average] | if length==0 then 0 else (add/length) end')
  avg=${avg:-0}
  avg_fmt=$(printf "%.2f" "$avg")
  echo "  avg CPU over ${DAYS}d = ${avg_fmt}%"
  is_idle=$(awk -v v="$avg" -v t="$CPU_THRESHOLD" 'BEGIN{print (v <= t) ? 1 : 0}')
  if [[ $is_idle -eq 1 ]]; then
    candidates+=("$d:$avg_fmt")
  fi
done

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "No idle OpenSearch domains found based on CPU threshold."; exit 0
fi

echo "\nCandidate idle domains:"
for c in "${candidates[@]}"; do
  d=${c%%:*}
  a=${c#*:}
  echo " - $d avg_cpu=${a}%"
done

if [[ "$DO_TAG" == false ]]; then
  echo "\nNo action requested. To tag these domains re-run with --tag --no-dry-run"
  exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "\nDRY RUN: would tag the candidate domains with Key=idle_candidate,Value=true. Re-run with --no-dry-run to apply."
  exit 0
fi

echo "Tagging candidate domains (best-effort)..."
for c in "${candidates[@]}"; do
  d=${c%%:*}
  # try to obtain ARN via describe-domain
  arn=$(${OS[*]} describe-domain --domain-name "$d" --query 'DomainStatus.ARN' --output text 2>/dev/null || echo '')
  if [[ -z "$arn" ]]; then
    # fallback to es describe-domain
    arn=$(aws es describe-elasticsearch-domain --domain-name "$d" --query 'DomainStatus.ARN' --output text 2>/dev/null || echo '')
  fi
  if [[ -n "$arn" && "$arn" != "None" ]]; then
    echo "Tagging $d -> $arn"
    aws opensearch tag-resource --arn "$arn" --tags Key=idle_candidate,Value=true 2>/dev/null || aws es add-tags --arn "$arn" --tags Key=idle_candidate,Value=true 2>/dev/null || echo "Failed to tag $d"
  else
    echo "Could not determine ARN for $d; printing suggested tag command: aws opensearch tag-resource --arn <ARN> --tags Key=idle_candidate,Value=true"
  fi
done

echo "Done."
