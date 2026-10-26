#!/usr/bin/env bash
# Builds and tests every Swift package under Packages/ on the macOS runner.
#   * default:            `swift test` on the macOS host (packages declare
#                          platforms [.iOS(.v18), .macOS(.v15)] for this)
#   * IOS_ONLY marker:    the package imports UIKit/HomeKit/etc. that does not
#                          exist on macOS; tested with xcodebuild on an iOS
#                          simulator instead
#   * no test targets:    build only
# Continues after a failure and exits non-zero at the end if any package failed.
# Result bundles / logs go to $ARTIFACTS_DIR (default: artifacts/).
# Usage: tools/ci/test-packages-macos.sh [Packages/Foo ...]
. "$(dirname "$0")/lib.sh"

out="${ARTIFACTS_DIR:-$REPO_ROOT/artifacts}"
mkdir -p "$out"
pkgs=()
if [ "$#" -gt 0 ]; then pkgs=("$@"); else
  while IFS= read -r line; do [ -n "$line" ] && pkgs+=("$line"); done < <(list_packages)
fi
if [ "${#pkgs[@]}" -eq 0 ]; then
  warn "no Swift packages under Packages/ yet; nothing to test"
  exit 0
fi

sim_id=""
failed=()
for p in "${pkgs[@]}"; do
  dir="$REPO_ROOT/$p"
  slug="$(printf '%s' "$p" | tr '/' '_')"
  group_start "$p"
  ok=1
  if [ -f "$dir/IOS_ONLY" ]; then
    [ -n "$sim_id" ] || sim_id="$(bash "$CI_DIR/pick-simulator.sh")"
    # SwiftPM packages get an auto-generated "<Name>-Package" scheme when they
    # have several products, otherwise a scheme named after the single product.
    scheme="$(cd "$dir" && xcodebuild -list -json 2>/dev/null \
      | jq -r '(.workspace // .project).schemes as $s | ($s | map(select(endswith("-Package"))) | first) // $s[0] // empty')"
    [ -n "$scheme" ] || { warn "$p: no scheme found"; scheme="$(basename "$p")"; }
    action="build"; has_tests "$dir" && action="test"
    rm -rf "$out/$slug.xcresult"
    (cd "$dir" && set -o pipefail && xcodebuild "$action" \
        -scheme "$scheme" \
        -destination "id=$sim_id" \
        -derivedDataPath "$REPO_ROOT/.ci/DerivedData-packages" \
        -resultBundlePath "$out/$slug.xcresult" \
        -skipPackagePluginValidation -skipMacroValidation \
        CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$out/$slug.log") || ok=0
  else
    (cd "$dir" && set -o pipefail && {
        swift build 2>&1 && if has_tests "$dir"; then swift test --parallel 2>&1; else echo "no test targets; build only"; fi
     } | tee "$out/$slug.log") || ok=0
  fi
  group_end
  if [ "$ok" -eq 1 ]; then log "PASS $p"; else warn "FAIL $p"; failed+=("$p"); fi
done

if [ "${#failed[@]}" -gt 0 ]; then die "package failures: ${failed[*]}"; fi
log "all ${#pkgs[@]} package(s) passed"
