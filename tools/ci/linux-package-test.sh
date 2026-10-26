#!/usr/bin/env bash
# Builds and tests one Swift package on Linux. Runs INSIDE a swift:6.x container
# (CI job linux-codecs.yml, or tools/ci/linux-local.sh on the Windows dev box).
# Usage: tools/ci/linux-package-test.sh Packages/LightCore
. "$(dirname "$0")/lib.sh"

pkg="${1:?usage: $0 <package dir relative to repo root>}"
dir="$REPO_ROOT/$pkg"
[ -f "$dir/Package.swift" ] || die "$pkg has no Package.swift"

swift --version
# SwiftPM shells out to git; containers run as root on a foreign-owned checkout.
git config --global --add safe.directory '*' 2>/dev/null || true

cd "$dir"
group_start "swift build ($pkg)"
swift build
group_end

if has_tests "$dir"; then
  group_start "swift test ($pkg)"
  swift test --parallel
  group_end
else
  warn "$pkg declares no test targets; build only"
fi
