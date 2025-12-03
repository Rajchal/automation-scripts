#!/usr/bin/env bash
set -euo pipefail

# kube-pod-image-updater.sh
# Find Deployments/DaemonSets/StatefulSets using a specific image:tag and optionally update to a new tag.
# Dry-run by default. Use --no-dry-run to apply changes.

usage(){
  cat <<EOF
Usage: $0 --image-name NAME --from-tag TAG --to-tag TAG [--kind deployment|daemonset|statefulset|all] [--namespace NAMESPACE | --all-namespaces] [--label-selector SELECTOR] [--no-dry-run]

Options:
  --image-name NAME        Image name (e.g. myrepo/myapp or myapp)
  --from-tag TAG           Current tag to match (e.g. 1.2.3)
  --to-tag TAG             New tag to apply (e.g. latest)
  --kind K                 Resource kind: deployment (default), daemonset, statefulset, all
  --namespace NAMESPACE    Namespace to search (default current)
  --all-namespaces         Search all namespaces
  --label-selector SEL     Only consider resources matching this selector
  --no-dry-run             Actually perform the image updates
  -h, --help               Show this help

Examples:
  # Dry-run: find deployments using myapp:1.2.3
  bash/kube-pod-image-updater.sh --image-name myapp --from-tag 1.2.3

  # Apply: update matched containers to myapp:latest across all namespaces
  bash/kube-pod-image-updater.sh --image-name myapp --from-tag 1.2.3 --to-tag latest --all-namespaces --no-dry-run

EOF
}

IMAGE_NAME=""
FROM_TAG=""
TO_TAG=""
KIND="deployment"
NAMESPACE=""
ALL_NS=false
LABEL_SELECTOR=""
DRY_RUN=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-name) IMAGE_NAME="$2"; shift 2;;
    --from-tag) FROM_TAG="$2"; shift 2;;
    --to-tag) TO_TAG="$2"; shift 2;;
    --kind) KIND="$2"; shift 2;;
    --namespace) NAMESPACE="$2"; shift 2;;
    --all-namespaces) ALL_NS=true; shift;;
    --label-selector) LABEL_SELECTOR="$2"; shift 2;;
    --no-dry-run) DRY_RUN=false; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 2;;
  esac
done

if [[ -z "$IMAGE_NAME" || -z "$FROM_TAG" || -z "$TO_TAG" ]]; then
  echo "--image-name, --from-tag and --to-tag are required"; usage; exit 2
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required"; exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"; exit 3
fi

case "$KIND" in
  deployment|daemonset|statefulset|all) ;;
  *) echo "Unsupported kind: $KIND"; exit 2;;
esac

echo "kube-pod-image-updater: image=${IMAGE_NAME}:${FROM_TAG} -> ${TO_TAG} kind=${KIND} namespace=${NAMESPACE:-current} all-namespaces=$ALL_NS dry-run=$DRY_RUN"

kubectl_args=(get)
resources=()

collect_resources(){
  local kind=$1
  local args=("$kind" -o json)
  if [[ -n "$LABEL_SELECTOR" ]]; then
    args+=(--selector "$LABEL_SELECTOR")
  fi
  if [[ "$ALL_NS" == true ]]; then
    args+=(--all-namespaces)
  elif [[ -n "$NAMESPACE" ]]; then
    args+=(-n "$NAMESPACE")
  fi
  out=$(kubectl "${args[@]}" 2>/dev/null || echo '{}')
  mapfile -t items < <(echo "$out" | jq -c '.items[]?')
  for it in "${items[@]}"; do
    resources+=("$kind:::${it}")
  done
}

if [[ "$KIND" == "all" ]]; then
  collect_resources deployments
  collect_resources daemonsets
  collect_resources statefulsets
else
  collect_resources ${KIND}s
fi

if [[ ${#resources[@]} -eq 0 ]]; then
  echo "No resources found for kind=${KIND} with the provided selector/namespace."; exit 0
fi

declare -a changes

for r in "${resources[@]}"; do
  # r is like 'deployments:::{json}'
  kind=${r%%:::*}
  json=${r#*:::}
  ns=$(echo "$json" | jq -r '.metadata.namespace // "default"')
  name=$(echo "$json" | jq -r '.metadata.name')

  # iterate containers
  mapfile -t ctrs < <(echo "$json" | jq -c '.spec.template.spec.containers[]?')
  for c in "${ctrs[@]}"; do
    cname=$(echo "$c" | jq -r '.name')
    image=$(echo "$c" | jq -r '.image')
    # simple parse: split at last ':' to get tag (works for typical images)
    img_name=${image%:*}
    img_tag=${image##*:}
    if [[ "$img_name" == "$IMAGE_NAME" && "$img_tag" == "$FROM_TAG" ]]; then
      new_image="$IMAGE_NAME:$TO_TAG"
      echo "Found match: $kind/$name (ns=$ns) container=$cname image=$image -> $new_image"
      changes+=("$kind|$ns|$name|$cname|$image|$new_image")
    fi
  done
done

if [[ ${#changes[@]} -eq 0 ]]; then
  echo "No matching containers found for ${IMAGE_NAME}:${FROM_TAG}."; exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "\nDRY RUN: the following updates would be applied (re-run with --no-dry-run to apply):"
  for ch in "${changes[@]}"; do
    IFS='|' read -r kind ns name cname old new <<< "$ch"
    echo "  $kind/$name (ns=$ns) container=$cname: $old -> $new"
  done
  exit 0
fi

echo "\nApplying updates..."
for ch in "${changes[@]}"; do
  IFS='|' read -r kind ns name cname old new <<< "$ch"
  # perform kubectl set image
  target="${kind%?}/$name" # convert deployments -> deployment
  if [[ "$kind" == "deployments" ]]; then
    target="deployment/$name"
  elif [[ "$kind" == "daemonsets" ]]; then
    target="daemonset/$name"
  elif [[ "$kind" == "statefulsets" ]]; then
    target="statefulset/$name"
  fi
  echo "Updating $target (ns=$ns) container=$cname -> $new"
  if [[ -n "$ns" ]]; then
    kubectl set image "$target" "$cname=$new" -n "$ns" --record || echo "  Failed to update $target container $cname"
  else
    kubectl set image "$target" "$cname=$new" --record || echo "  Failed to update $target container $cname"
  fi
done

echo "\nDone."
