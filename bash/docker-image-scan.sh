#!/usr/bin/env bash
set -euo pipefail

# docker-image-scan.sh
# Scan container images for vulnerabilities using trivy or docker scan.
# Produces a summary report with counts by severity.
# Dry-run by default (reports only); use --save-report to write JSON output.

usage(){
  cat <<EOF
Usage: $0 --image IMAGE [--scanner trivy|docker|auto] [--severity LEVEL] [--save-report FILE] [--no-dry-run]

Options:
  --image IMAGE            Container image to scan (e.g. nginx:latest or gcr.io/my-project/app:v1)
  --scanner SCANNER        Scanner to use: trivy (default), docker, or auto (try trivy first)
  --severity LEVEL         Minimum severity to report: CRITICAL,HIGH,MEDIUM,LOW,UNKNOWN (default all)
  --save-report FILE       Write detailed JSON/text report to FILE
  --no-dry-run             Perform the scan (default is already active for --image)
  -h, --help               Show this help

Examples:
  # Scan using trivy (default)
  bash/docker-image-scan.sh --image nginx:latest

  # Scan using docker scan and filter for CRITICAL+HIGH only
  bash/docker-image-scan.sh --image myrepo/myapp:v1 --scanner docker --severity CRITICAL,HIGH

  # Save detailed JSON report
  bash/docker-image-scan.sh --image myapp:latest --scanner trivy --save-report scan_report.json

EOF
}

IMAGE=""
SCANNER="auto"
SEVERITY=""
SAVE_REPORT=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2;;
    --scanner) SCANNER="$2"; shift 2;;
    --severity) SEVERITY="$2"; shift 2;;
    --save-report) SAVE_REPORT="$2"; shift 2;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if [[ -z "$IMAGE" ]]; then
  echo "--image is required"; usage; exit 2
fi

case "$SCANNER" in
  trivy|docker|auto) ;;
  *) echo "Unsupported scanner: $SCANNER"; exit 2;;
esac

echo "docker-image-scan: image=$IMAGE scanner=$SCANNER severity=${SEVERITY:-all} save_report=${SAVE_REPORT:-none}"

# Determine which scanner to use
chosen_scanner=""

if [[ "$SCANNER" == "auto" ]]; then
  if command -v trivy >/dev/null 2>&1; then
    chosen_scanner="trivy"
  elif command -v docker >/dev/null 2>&1; then
    chosen_scanner="docker"
  else
    echo "Error: neither trivy nor docker is available"; exit 3
  fi
elif [[ "$SCANNER" == "trivy" ]]; then
  if ! command -v trivy >/dev/null 2>&1; then
    echo "Error: trivy is not installed"; exit 3
  fi
  chosen_scanner="trivy"
elif [[ "$SCANNER" == "docker" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "Error: docker is not installed"; exit 3
  fi
  chosen_scanner="docker"
fi

echo "Using scanner: $chosen_scanner"

perform_scan(){
  local scan_format="json"
  local report_file=""

  if [[ -n "$SAVE_REPORT" ]]; then
    report_file="$SAVE_REPORT"
  else
    report_file=$(mktemp)
  fi

  echo "Scanning image: $IMAGE"

  if [[ "$chosen_scanner" == "trivy" ]]; then
    # Run trivy
    trivy image --format json --output "$report_file" "$IMAGE" 2>/dev/null || {
      echo "Trivy scan failed"; return 1
    }
  elif [[ "$chosen_scanner" == "docker" ]]; then
    # Run docker scan (requires docker scout or legacy docker scan)
    if docker scan "$IMAGE" --json > "$report_file" 2>/dev/null; then
      :
    else
      echo "Docker scan failed"; return 1
    fi
  fi

  # Parse and summarize
  if command -v jq >/dev/null 2>&1; then
    echo ""
    echo "=== Vulnerability Summary ==="
    # Try to extract severity counts from JSON
    if [[ "$chosen_scanner" == "trivy" ]]; then
      jq -r '.Results[]? | select(.Vulnerabilities) | .Vulnerabilities[]? | .Severity' "$report_file" 2>/dev/null | sort | uniq -c || echo "Could not parse results"
    elif [[ "$chosen_scanner" == "docker" ]]; then
      jq -r '.vulnerabilities[]? | .severity' "$report_file" 2>/dev/null | sort | uniq -c || echo "Could not parse results"
    fi
  else
    echo "jq not found; cannot parse JSON summary. Raw report saved to: $report_file"
  fi

  if [[ -n "$SAVE_REPORT" ]]; then
    echo "Full report saved to: $report_file"
  else
    rm -f "$report_file"
  fi
}

perform_scan

echo "Done."
