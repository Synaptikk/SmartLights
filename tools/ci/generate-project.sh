#!/usr/bin/env bash
# Generates SmartLights.xcodeproj from project.yml with XcodeGen.
# Exits 0 without doing anything if project.yml does not exist yet.
# XCODEGEN_VERSION pins a release (default: Homebrew's current formula).
. "$(dirname "$0")/lib.sh"

cd "$REPO_ROOT"
if [ ! -f project.yml ]; then
  warn "project.yml not found; skipping project generation"
  exit 0
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  if [ -n "${XCODEGEN_VERSION:-}" ]; then
    log "installing XcodeGen $XCODEGEN_VERSION from GitHub release"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/xcodegen.zip" \
      "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
    unzip -q "$tmp/xcodegen.zip" -d "$tmp"
    export PATH="$tmp/xcodegen/bin:$PATH"
    if [ -n "${GITHUB_PATH:-}" ]; then echo "$tmp/xcodegen/bin" >> "$GITHUB_PATH"; fi
  else
    log "installing XcodeGen via Homebrew"
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install xcodegen
  fi
fi
xcodegen --version
xcodegen generate --spec project.yml
