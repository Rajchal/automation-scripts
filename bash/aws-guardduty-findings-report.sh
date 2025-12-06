#!/usr/bin/env bash
set -euo pipefail

# aws-guardduty-findings-report.sh
# Generate a report of AWS GuardDuty findings with severity filtering.
# Can export to JSON or formatted text report.
# Dry-run by default; use --no-dry-run to fetch findings.

usage(){
  cat <<EOF
Usage: $0 [--region REGION] [--severity LEVEL] [--days N] [--format FORMAT] [--no-dry-run]

Options:
  --region REGION          AWS region (uses AWS_DEFAULT_REGION if unset)
  --severity LEVEL         Filter by severity: Low, Medium, High (default: High)
  --days N                 Look back N days (default: 7)
  --format FORMAT          Output format: text or json (default: text)
  --no-dry-run             Fetch GuardDuty findings (default: dry-run)
  -h, --help               Show this help

Examples:
  # Dry-run: show what would be queried
  bash/aws-guardduty-findings-report.sh --severity High

  # Get high severity findings from last 24 hours
  bash/aws-guardduty-findings-report.sh --severity High --days 1 --no-dry-run

  # Export medium/high findings to JSON
  bash/aws-guardduty-findings-report.sh --severity Medium --format json --no-dry-run > findings.json

EOF
}

REGION=""
SEVERITY="High"
DAYS=7
FORMAT="text"
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --severity) SEVERITY="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --format) FORMAT="$2"; shift 2;;
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

AWS=(aws guardduty)
if [[ -n "$REGION" ]]; then
  AWS+=(--region "$REGION")
fi

echo "GuardDuty Findings Report: severity=$SEVERITY days=$DAYS format=$FORMAT dry-run=$DRY_RUN" >&2

if [[ "$DRY_RUN" == true ]]; then
  echo "DRY RUN: would fetch GuardDuty findings for last $DAYS days with severity >= $SEVERITY" >&2
  exit 0
fi

# Get GuardDuty detector ID
echo "Finding GuardDuty detector..." >&2
detector_id=$("${AWS[@]}" list-detectors --query 'DetectorIds[0]' --output text 2>/dev/null || echo "")

if [[ -z "$detector_id" || "$detector_id" == "None" ]]; then
  echo "No GuardDuty detector found in this region. Is GuardDuty enabled?" >&2
  exit 1
fi

echo "Detector: $detector_id" >&2

# Calculate time range (milliseconds since epoch)
now_ms=$(date +%s%3N)
start_ms=$(date -d "$DAYS days ago" +%s%3N)

# Severity mapping (GuardDuty uses numeric ranges)
# Low: 0.1-3.9, Medium: 4.0-6.9, High: 7.0-8.9, Critical: 9.0-10.0
case "$SEVERITY" in
  Low) min_severity=0.1;;
  Medium) min_severity=4.0;;
  High) min_severity=7.0;;
  Critical) min_severity=9.0;;
  *) min_severity=7.0;;
esac

# Build finding criteria
criteria=$(cat <<EOF
{
  "Criterion": {
    "updatedAt": {
      "Gte": $start_ms
    },
    "severity": {
      "Gte": $min_severity
    }
  }
}
EOF
)

echo "Fetching findings..." >&2

# List finding IDs
finding_ids=$("${AWS[@]}" list-findings \
  --detector-id "$detector_id" \
  --finding-criteria "$criteria" \
  --query 'FindingIds' \
  --output json 2>/dev/null || echo '[]')

finding_count=$(echo "$finding_ids" | jq '. | length')

if [[ "$finding_count" -eq 0 ]]; then
  echo "No findings matching criteria." >&2
  exit 0
fi

echo "Found $finding_count finding(s)" >&2

# Get finding details
findings_json=$("${AWS[@]}" get-findings \
  --detector-id "$detector_id" \
  --finding-ids $(echo "$finding_ids" | jq -r '.[]' | tr '\n' ' ') \
  --output json 2>/dev/null || echo '{"Findings":[]}')

if [[ "$FORMAT" == "json" ]]; then
  echo "$findings_json"
else
  echo "" >&2
  echo "=== GuardDuty Findings Report ===" >&2
  echo "Time Range: Last $DAYS day(s)" >&2
  echo "Severity: >= $SEVERITY" >&2
  echo "" >&2
  
  echo "$findings_json" | jq -r '.Findings[] | 
    "ID: \(.Id)",
    "Type: \(.Type)",
    "Severity: \(.Severity) (\(.Title))",
    "Region: \(.Region)",
    "Resource: \(.Resource.ResourceType) - \(.Resource.InstanceDetails.InstanceId // .Resource.S3BucketDetails[0].Name // "N/A")",
    "Description: \(.Description)",
    "First Seen: \(.Service.EventFirstSeen)",
    "Last Seen: \(.Service.EventLastSeen)",
    "Count: \(.Service.Count)",
    "---"
  '
fi

echo "" >&2
echo "Report complete." >&2
