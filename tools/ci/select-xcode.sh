#!/usr/bin/env bash
# Selects the Xcode used by the rest of the job (macOS runners only).
#   XCODE_VERSION unset  -> the image default (/Applications/Xcode.app)
#   XCODE_VERSION=27.1   -> /Applications/Xcode_27.1.app, else newest Xcode_27.1*.app
#   XCODE_VERSION=27     -> /Applications/Xcode_27.app, else newest Xcode_27*.app
# Exports DEVELOPER_DIR to later steps via $GITHUB_ENV.
# Warns (does not fail) if the selected Xcode is older than MIN_XCODE_MAJOR (27).
. "$(dirname "$0")/lib.sh"

want="${XCODE_VERSION:-}"
min_major="${MIN_XCODE_MAJOR:-27}"
app=""
if [ -z "$want" ]; then
  app="/Applications/Xcode.app"
elif [ -d "/Applications/Xcode_${want}.app" ]; then
  app="/Applications/Xcode_${want}.app"
else
  # Newest match, ignoring beta/RC bundles unless nothing else matches.
  app="$(ls -d /Applications/Xcode_"${want}"*.app 2>/dev/null | grep -viE 'beta|candidate' | sort -V | tail -1 || true)"
  [ -n "$app" ] || app="$(ls -d /Applications/Xcode_"${want}"*.app 2>/dev/null | sort -V | tail -1 || true)"
fi
if [ -z "$app" ] || [ ! -d "$app" ]; then
  log "installed Xcodes:"; ls -d /Applications/Xcode*.app >&2 || true
  die "no Xcode matching XCODE_VERSION='${want}'"
fi

sudo xcode-select -s "$app/Contents/Developer"
if [ -n "${GITHUB_ENV:-}" ]; then echo "DEVELOPER_DIR=$app/Contents/Developer" >> "$GITHUB_ENV"; fi
xcodebuild -version
swift --version

# Capture first, then parse: piping into a reader that exits early (awk `exit`, head) makes
# xcodebuild die on SIGPIPE (NSFileHandleOperationException, exit 134) and pipefail fails the step.
version_output="$(xcodebuild -version)"
major="$(printf '%s\n' "$version_output" | awk '/^Xcode/{split($2,v,"."); m=v[1]} END{print m}')"
if [ "${major:-0}" -lt "$min_major" ]; then
  warn "Selected Xcode $major is older than the project's required Xcode $min_major (CLAUDE.md). Set repo variable MACOS_RUNNER / XCODE_VERSION."
fi
