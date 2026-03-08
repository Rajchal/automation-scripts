#!/usr/bin/env bash
set -euo pipefail

# Audit Terraform modules for risky source usage.
# Checks:
# 1) Git module sources missing ?ref= pin
# 2) Registry modules missing explicit version
# 3) Insecure http:// module sources

usage() {
  cat <<EOF
Usage: $0 [--dir PATH] [--allow-local] [--no-fail]

Options:
  --dir PATH      Terraform root directory to scan (default: current directory)
  --allow-local   Do not flag local module paths (./, ../, /path)
  --no-fail       Always exit 0 even when findings exist
  -h, --help      Show this help message

Examples:
  # Audit current directory and fail on findings
  bash/terraform-module-source-auditor.sh

  # Audit specific infrastructure folder
  bash/terraform-module-source-auditor.sh --dir infra/prod

  # Allow local modules and keep CI green (report-only)
  bash/terraform-module-source-auditor.sh --allow-local --no-fail
EOF
}

DIR="."
ALLOW_LOCAL=false
NO_FAIL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="${2:-}"; shift 2 ;;
    --allow-local) ALLOW_LOCAL=true; shift ;;
    --no-fail) NO_FAIL=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ! -d "$DIR" ]]; then
  echo "Directory not found: $DIR" >&2
  exit 2
fi

if ! command -v awk >/dev/null 2>&1; then
  echo "awk is required" >&2
  exit 3
fi

mapfile -t tf_files < <(find "$DIR" -type f -name '*.tf' | sort)
if [[ ${#tf_files[@]} -eq 0 ]]; then
  echo "No Terraform files found under: $DIR"
  exit 0
fi

echo "Terraform Module Source Auditor"
echo "Scan dir: $DIR"
echo "Terraform files: ${#tf_files[@]}"

declare -i findings=0

audit_file() {
  local file="$1"
  awk -v file="$file" -v allow_local="$ALLOW_LOCAL" '
    function ltrim(s) { sub(/^[ \t\r\n]+/, "", s); return s }
    function rtrim(s) { sub(/[ \t\r\n]+$/, "", s); return s }
    function trim(s) { return rtrim(ltrim(s)) }

    BEGIN {
      in_module=0
      module_name=""
      source=""
      version=""
      line_source=0
      line_version=0
      local_findings=0
    }

    /^[ \t]*module[ \t]+"[^"]+"[ \t]*\{/ {
      in_module=1
      module_name=$0
      sub(/^[ \t]*module[ \t]+"/, "", module_name)
      sub(/"[ \t]*\{.*/, "", module_name)
      source=""
      version=""
      line_source=0
      line_version=0
      next
    }

    in_module && /^[ \t]*source[ \t]*=/ {
      s=$0
      sub(/^[^=]*=[ \t]*/, "", s)
      gsub(/"/, "", s)
      gsub(/#.*/, "", s)
      source=trim(s)
      line_source=NR
      next
    }

    in_module && /^[ \t]*version[ \t]*=/ {
      v=$0
      sub(/^[^=]*=[ \t]*/, "", v)
      gsub(/"/, "", v)
      gsub(/#.*/, "", v)
      version=trim(v)
      line_version=NR
      next
    }

    in_module && /^[ \t]*}/ {
      if (source != "") {
        if (source ~ /^http:\/\//) {
          printf("FINDING|%s|%d|%s|insecure_http_source|%s\n", file, line_source, module_name, source)
          local_findings++
        }

        if (source ~ /^git::/ && source !~ /\?ref=/) {
          printf("FINDING|%s|%d|%s|git_source_not_pinned|%s\n", file, line_source, module_name, source)
          local_findings++
        }

        # Terraform registry shorthand (namespace/name/provider) usually should set version.
        if (source ~ /^[A-Za-z0-9_-]+\/[A-Za-z0-9_-]+\/[A-Za-z0-9_-]+$/ && version == "") {
          printf("FINDING|%s|%d|%s|registry_module_missing_version|%s\n", file, line_source, module_name, source)
          local_findings++
        }

        if (allow_local != "true" && (source ~ /^\.\// || source ~ /^\.\.\// || source ~ /^\//)) {
          printf("FINDING|%s|%d|%s|local_module_source|%s\n", file, line_source, module_name, source)
          local_findings++
        }
      }

      in_module=0
      module_name=""
      source=""
      version=""
      line_source=0
      line_version=0
      next
    }

    END {
      if (local_findings == 0) {
        # No output for clean files to keep logs concise.
      }
    }
  ' "$file"
}

for tf in "${tf_files[@]}"; do
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    IFS='|' read -r tag fpath lnum module issue detail <<< "$line"
    if [[ "$tag" == "FINDING" ]]; then
      findings+=1
      printf '[%s] %s:%s module="%s" source="%s"\n' "$issue" "$fpath" "$lnum" "$module" "$detail"
    fi
  done < <(audit_file "$tf")
done

echo ""
echo "Total findings: $findings"

if (( findings > 0 )) && [[ "$NO_FAIL" == false ]]; then
  exit 1
fi

exit 0
