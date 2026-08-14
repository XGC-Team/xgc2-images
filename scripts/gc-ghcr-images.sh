#!/usr/bin/env bash
set -euo pipefail

owner="${GITHUB_REPOSITORY_OWNER:-}"
repo="${GITHUB_REPOSITORY_NAME:-}"
catalog="catalog/index.yml"
owner_type="org"
app_filter="all"
keep_last=0
delete=false

usage() {
  cat <<'EOF'
Usage: scripts/gc-ghcr-images.sh [options]

List or delete stale GHCR app image packages for the current catalog.

Options:
  --owner OWNER          GitHub user or organization that owns the packages.
  --repo REPO            Repository/package namespace, for example xgc2-images.
  --owner-type TYPE      user or org. Default: org.
  --catalog PATH         Catalog file. Default: catalog/index.yml.
  --app APP              Restrict to one stale app key. Default: all.
  --keep-last N          Keep the newest N package versions for stale packages. Default: 0.
  --delete               Delete selected package versions. Omit for dry-run.
  -h, --help             Show this help.

Required tools: gh, jq, ruby.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner)
      owner="${2:?missing owner}"
      shift 2
      ;;
    --repo)
      repo="${2:?missing repo}"
      shift 2
      ;;
    --owner-type)
      owner_type="${2:?missing owner type}"
      shift 2
      ;;
    --catalog)
      catalog="${2:?missing catalog path}"
      shift 2
      ;;
    --app)
      app_filter="${2:?missing app key}"
      shift 2
      ;;
    --keep-last)
      keep_last="${2:?missing keep-last value}"
      shift 2
      ;;
    --delete)
      delete=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$owner" || -z "$repo" ]]; then
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    owner="${owner:-${GITHUB_REPOSITORY%%/*}}"
    repo="${repo:-${GITHUB_REPOSITORY#*/}}"
  fi
fi

if [[ -z "$owner" || -z "$repo" ]]; then
  echo "--owner and --repo are required outside GitHub Actions." >&2
  exit 2
fi
if [[ "$owner_type" != "user" && "$owner_type" != "org" ]]; then
  echo "--owner-type must be user or org." >&2
  exit 2
fi
if ! [[ "$keep_last" =~ ^[0-9]+$ ]]; then
  echo "--keep-last must be a non-negative integer." >&2
  exit 2
fi
for tool in gh jq ruby; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 2
  fi
done
if [[ ! -f "$catalog" ]]; then
  echo "Catalog not found: $catalog" >&2
  exit 2
fi

api_owner_path() {
  if [[ "$owner_type" == "org" ]]; then
    printf '/orgs/%s' "$owner"
  else
    printf '/users/%s' "$owner"
  fi
}

urlencode() {
  jq -nr --arg value "$1" '$value | @uri'
}

active_apps_json="$(
  ruby -ryaml -rjson -rdate -e '
    doc = YAML.safe_load_file(ARGV[0], permitted_classes: [Date])
    puts Array(doc["apps"]).map { |app| app.fetch("key") }.uniq.to_json
  ' "$catalog"
)"

package_prefix="${repo}/"
owner_path="$(api_owner_path)"

packages_api="${owner_path}/packages?package_type=container&per_page=100"
echo "Listing GHCR packages from ${packages_api}" >&2
api_error_file="$(mktemp)"
if ! packages_json="$(
  gh api --paginate "$packages_api" \
    --jq '[.[] | select(.name | startswith("'"${package_prefix}"'")) | {name: .name, visibility: .visibility}]' \
    2>"$api_error_file" \
    | jq -s 'add'
)"; then
  echo "Failed to list GHCR packages for ${owner_type} ${owner}." >&2
  cat "$api_error_file" >&2
  rm -f "$api_error_file"
  echo "Configure a GHCR_GC_TOKEN repository secret with read:packages and delete:packages scopes, then rerun the workflow." >&2
  exit 1
fi
rm -f "$api_error_file"

stale_packages_json="$(
  jq -n \
    --arg prefix "$package_prefix" \
    --arg app "$app_filter" \
    --argjson active "$active_apps_json" \
    --argjson packages "$packages_json" '
      $packages
      | map(. + {appKey: (.name | sub("^" + ($prefix | gsub("([\\^$.|?*+(){}\\[\\]\\\\])"; "\\\\\\1")); ""))})
      | map(select($active | index(.appKey) | not))
      | if $app == "all" then . else map(select(.appKey == $app)) end
    '
)"

summary_json="$(
  jq -n \
    --arg owner "$owner" \
    --arg repo "$repo" \
    --arg ownerType "$owner_type" \
    --argjson active "$active_apps_json" \
    --argjson stale "$stale_packages_json" \
    --argjson delete "$delete" \
    --argjson keepLast "$keep_last" '
      {
        owner: $owner,
        repo: $repo,
        ownerType: $ownerType,
        delete: $delete,
        keepLast: $keepLast,
        activeApps: $active,
        stalePackages: $stale
      }
    '
)"

echo "$summary_json" | jq .

if [[ "$(jq 'length' <<<"$stale_packages_json")" -eq 0 ]]; then
  echo "No stale GHCR app packages found."
  exit 0
fi

if [[ "$delete" != "true" ]]; then
  echo "Dry-run only. Re-run with --delete to remove selected stale package versions."
  exit 0
fi

while IFS= read -r package_name; do
  [[ -z "$package_name" ]] && continue
  encoded_package="$(urlencode "$package_name")"
  versions_json="$(
    gh api --paginate "${owner_path}/packages/container/${encoded_package}/versions?per_page=100" \
      --jq '[.[] | {id: .id, name: .name, created_at: .created_at, metadata: .metadata}]' \
      | jq -s 'add | sort_by(.created_at) | reverse'
  )"
  delete_versions_json="$(jq --argjson keep "$keep_last" 'if $keep == 0 then . else .[$keep:] end' <<<"$versions_json")"
  kept_versions_json="$(jq --argjson keep "$keep_last" 'if $keep == 0 then [] else .[:$keep] end' <<<"$versions_json")"

  echo "Package: $package_name"
  echo "Keeping versions:"
  jq -r '.[] | "  id=\(.id) created_at=\(.created_at) tags=\((.metadata.container.tags // []) | join(","))"' <<<"$kept_versions_json"
  echo "Deleting versions:"
  jq -r '.[] | "  id=\(.id) created_at=\(.created_at) tags=\((.metadata.container.tags // []) | join(","))"' <<<"$delete_versions_json"

  while IFS= read -r version_id; do
    [[ -z "$version_id" ]] && continue
    gh api \
      --method DELETE \
      "${owner_path}/packages/container/${encoded_package}/versions/${version_id}"
  done < <(jq -r '.[].id' <<<"$delete_versions_json")
done < <(jq -r '.[].name' <<<"$stale_packages_json")
