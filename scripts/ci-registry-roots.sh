# Shared by GitHub Actions build jobs. Sets GHCR_ROOT and EXTRA_ROOT so both
# registries share EXTRA_NAMESPACE (a variable, not a credential). Apply this
# at push time; do not put the namespace into detect job outputs.
repo_lc="$(printf '%s' "${GITHUB_REPOSITORY}" | tr '[:upper:]' '[:lower:]')"
owner="${repo_lc%%/*}"
ns="$(printf '%s' "${EXTRA_NAMESPACE:-}" | sed 's#^/*##; s#/*$##')"
DEFAULT_GHCR_ROOT="ghcr.io/${repo_lc}"
if [[ -n "${ns}" ]]; then
  if [[ "${ns}" == */* ]]; then
    GHCR_ROOT="ghcr.io/${ns}"
  else
    GHCR_ROOT="ghcr.io/${owner}/${ns}"
  fi
else
  GHCR_ROOT="${DEFAULT_GHCR_ROOT}"
fi
EXTRA_ROOT=""
extra_secrets=0
for key in EXTRA_REGISTRY EXTRA_USERNAME EXTRA_PASSWORD; do
  [[ -n "${!key:-}" ]] && extra_secrets=$((extra_secrets + 1))
done
if [[ "${extra_secrets}" -eq 3 && -n "${ns}" ]]; then
  EXTRA_ROOT="${EXTRA_REGISTRY%/}/${ns}"
elif [[ "${extra_secrets}" -ne 0 ]]; then
  echo "extra registry is partially configured" >&2
  exit 1
fi
rewrite_ghcr() {
  printf '%s' "${1/#${DEFAULT_GHCR_ROOT}/${GHCR_ROOT}}"
}
