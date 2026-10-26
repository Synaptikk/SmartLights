#!/usr/bin/env bash
# Local equivalent of .github/workflows/linux-codecs.yml for the Windows dev box
# (Git Bash + Docker Desktop) or any Linux/macOS host with Docker.
# Usage:
#   tools/ci/linux-local.sh                      # every Linux package
#   tools/ci/linux-local.sh Packages/LightCore   # just one
#   SWIFT_IMAGE=swift:6.4 tools/ci/linux-local.sh
. "$(dirname "$0")/lib.sh"

image="${SWIFT_IMAGE:-swift:6.1}"
pkgs=()
if [ "$#" -gt 0 ]; then pkgs=("$@"); else
  while IFS= read -r line; do [ -n "$line" ] && pkgs+=("$line"); done < <(bash "$CI_DIR/find-linux-packages.sh" --lines)
fi
[ "${#pkgs[@]}" -gt 0 ] || { log "no Linux packages found"; exit 0; }

# Git Bash would rewrite /src paths into C:/Program Files/Git/src.
export MSYS_NO_PATHCONV=1
src="$REPO_ROOT"
if command -v cygpath >/dev/null 2>&1; then src="$(cygpath -w "$REPO_ROOT")"; fi

failed=()
for p in "${pkgs[@]}"; do
  log "[$image] $p"
  if ! docker run --rm -v "$src:/src" -w /src "$image" \
        bash tools/ci/linux-package-test.sh "$p"; then
    failed+=("$p")
  fi
done
if [ "${#failed[@]}" -gt 0 ]; then die "failed: ${failed[*]}"; fi
log "all Linux packages passed on $image"
