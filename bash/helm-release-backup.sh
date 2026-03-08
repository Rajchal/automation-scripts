#!/usr/bin/env bash
set -euo pipefail

# helm-release-backup.sh
# Backup Helm release metadata, values, and manifests for disaster recovery.

usage() {
  cat <<'EOF'
Usage: helm-release-backup.sh [options]

Options:
  --namespace NS         Backup only this namespace (default: all namespaces)
  --context CONTEXT      Kubernetes context to use
  --output-dir DIR       Output directory (default: ./helm-backups/<timestamp>)
  --include-hooks        Include hooks in manifest export
  -h, --help             Show this help message

Examples:
  # Backup all namespaces
  bash/helm-release-backup.sh

  # Backup only production namespace
  bash/helm-release-backup.sh --namespace production

  # Backup from a specific context to custom folder
  bash/helm-release-backup.sh --context prod-cluster --output-dir /tmp/helm-backup
EOF
}

NAMESPACE=""
CONTEXT=""
OUTPUT_DIR=""
INCLUDE_HOOKS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      NAMESPACE="${2:-}"
      shift 2
      ;;
    --context)
      CONTEXT="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --include-hooks)
      INCLUDE_HOOKS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if ! command -v helm >/dev/null 2>&1; then
  echo "Error: helm is required but not installed." >&2
  exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not installed." >&2
  exit 3
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  OUTPUT_DIR="./helm-backups/$ts"
fi

mkdir -p "$OUTPUT_DIR"

HELM=(helm)
if [[ -n "$CONTEXT" ]]; then
  HELM+=(--kube-context "$CONTEXT")
fi

echo "Starting Helm backup"
echo "  Namespace: ${NAMESPACE:-all namespaces}"
echo "  Context:   ${CONTEXT:-current}"
echo "  Output:    $OUTPUT_DIR"

tmp_list="$OUTPUT_DIR/.releases.json"
if [[ -n "$NAMESPACE" ]]; then
  "${HELM[@]}" list -n "$NAMESPACE" -o json > "$tmp_list"
else
  "${HELM[@]}" list -A -o json > "$tmp_list"
fi

release_count="$(jq 'length' "$tmp_list")"
if [[ "$release_count" -eq 0 ]]; then
  echo "No Helm releases found."
  rm -f "$tmp_list"
  exit 0
fi

echo "Found $release_count releases"

jq -c '.[]' "$tmp_list" | while IFS= read -r release; do
  name="$(jq -r '.name' <<< "$release")"
  ns="$(jq -r '.namespace' <<< "$release")"
  chart="$(jq -r '.chart' <<< "$release")"
  app_version="$(jq -r '.app_version // "unknown"' <<< "$release")"

  rel_dir="$OUTPUT_DIR/$ns/$name"
  mkdir -p "$rel_dir"

  echo "- Backing up release: $name (namespace: $ns, chart: $chart)"

  {
    echo "name=$name"
    echo "namespace=$ns"
    echo "chart=$chart"
    echo "app_version=$app_version"
    echo "backup_time=$(date -Is)"
    if [[ -n "$CONTEXT" ]]; then
      echo "context=$CONTEXT"
    fi
  } > "$rel_dir/metadata.env"

  "${HELM[@]}" get values "$name" -n "$ns" --all > "$rel_dir/values.yaml" || true

  manifest_args=(get manifest "$name" -n "$ns")
  if [[ "$INCLUDE_HOOKS" == true ]]; then
    manifest_args+=(--include-hooks)
  fi
  "${HELM[@]}" "${manifest_args[@]}" > "$rel_dir/manifest.yaml" || true

  "${HELM[@]}" history "$name" -n "$ns" -o json > "$rel_dir/history.json" || true
  "${HELM[@]}" status "$name" -n "$ns" -o json > "$rel_dir/status.json" || true

  printf '%s\n' "$release" > "$rel_dir/release-list-entry.json"
done

rm -f "$tmp_list"

echo "Backup completed successfully: $OUTPUT_DIR"
