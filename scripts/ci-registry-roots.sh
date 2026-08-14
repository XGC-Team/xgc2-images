# Shared by GitHub Actions build jobs. Sets GHCR_ROOT and EXTRA_ROOT so both
# registries share EXTRA_NAMESPACE. Do not print this from a detect job output.
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
if [[ -n "${EXTRA_REGISTRY:-}" && -n "${ns}" && -n "${EXTRA_USERNAME:-}" && -n "${EXTRA_PASSWORD:-}" ]]; then
  EXTRA_ROOT="${EXTRA_REGISTRY%/}/${ns}"
fi
rewrite_ghcr() {
  printf '%s' "${1/#${DEFAULT_GHCR_ROOT}/${GHCR_ROOT}}"
}
