#!/usr/bin/env bash
# Shared helpers for tools/ci/*.sh. Source it: . "$(dirname "$0")/lib.sh"
set -euo pipefail

# Repository root (tools/ci/../..).
CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CI_DIR/../.." && pwd)"
export CI_DIR REPO_ROOT

log()  { printf '[ci] %s\n' "$*" >&2; }
warn() { if [ -n "${GITHUB_ACTIONS:-}" ]; then printf '::warning::%s\n' "$*" >&2; else printf '[ci] WARNING: %s\n' "$*" >&2; fi; }
die()  { if [ -n "${GITHUB_ACTIONS:-}" ]; then printf '::error::%s\n' "$*" >&2; else printf '[ci] ERROR: %s\n' "$*" >&2; fi; exit 1; }
group_start() { if [ -n "${GITHUB_ACTIONS:-}" ]; then printf '::group::%s\n' "$*"; else printf '\n=== %s ===\n' "$*"; fi; }
group_end()   { if [ -n "${GITHUB_ACTIONS:-}" ]; then printf '::endgroup::\n'; fi; }

# Print every Swift package directory under Packages/ (relative to repo root),
# one per line, sorted. Skips build output and checked-out dependencies.
list_packages() {
  [ -d "$REPO_ROOT/Packages" ] || return 0
  (cd "$REPO_ROOT" && find Packages -name Package.swift \
      -not -path '*/.build/*' -not -path '*/.swiftpm/*' -not -path '*/checkouts/*' \
      -exec dirname {} \; | sort)
}

# True if the package declares at least one test target.
has_tests() {
  grep -Eq '\.testTarget[[:space:]]*\(' "$1/Package.swift"
}
