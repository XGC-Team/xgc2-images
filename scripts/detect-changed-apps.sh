#!/usr/bin/env bash
set -euo pipefail

base="${1:-}"
head_ref="${2:-HEAD}"

if [[ -z "$base" ]]; then
  if git rev-parse HEAD^ >/dev/null 2>&1; then
    base="HEAD^"
  else
    base="$(git hash-object -t tree /dev/null)"
  fi
fi

if [[ "$base" =~ ^0+$ ]] || ! git cat-file -e "$base" 2>/dev/null; then
  base="$(git hash-object -t tree /dev/null)"
fi

changed_files="$(git diff --name-status "$base" "$head_ref" || true)"
apps=()
deleted=()
rebuild_all_build_images=false

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  status="${file%%$'\t'*}"
  path="${file#*$'\t'}"
  if [[ "$path" =~ ^scripts/build/ ]] || [[ "$path" == ".github/workflows/build.yml" ]] || [[ "$path" == ".github/workflows/reusable-build-images.yml" ]] || [[ "$path" == ".github/workflows/reusable-build-chain.yml" ]] || [[ "$path" == "scripts/detect-ci-matrices.rb" ]]; then
    rebuild_all_build_images=true
  fi
  if [[ "$path" =~ ^apps/([^/]+)/ ]]; then
    app="${BASH_REMATCH[1]}"
    if [[ ! -d "apps/${app}" ]]; then
      if [[ ! " ${deleted[*]} " =~ " ${app} " ]]; then
        deleted+=("$app")
      fi
    elif [[ "$status" == D* ]]; then
      if [[ ! " ${apps[*]} " =~ " ${app} " && ! " ${deleted[*]} " =~ " ${app} " ]]; then
        apps+=("$app")
      fi
    elif [[ ! " ${apps[*]} " =~ " ${app} " ]]; then
      apps+=("$app")
    fi
  fi
done <<<"$changed_files"

if [[ "${rebuild_all_build_images}" == "true" ]]; then
  while IFS= read -r app_file; do
    app="$(basename "$(dirname "$app_file")")"
    type="$(awk -F': *' '/^type:/{print $2; exit}' "$app_file")"
    if [[ "${type}" == "build" && ! " ${apps[*]} " =~ " ${app} " ]]; then
      apps+=("$app")
    fi
  done < <(find apps -mindepth 2 -maxdepth 2 -name app.yml | sort)
fi

jq -n \
  --argjson apps "$(printf '%s\n' "${apps[@]}" | jq -R 'select(length > 0)' | jq -cs .)" \
  --argjson deleted "$(printf '%s\n' "${deleted[@]}" | jq -R 'select(length > 0)' | jq -cs .)" \
  '{apps: $apps, deleted: $deleted}'
