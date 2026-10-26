#!/usr/bin/env bash
# Builds the SmartLights app for an iOS simulator and runs its test action.
# Requires tools/ci/generate-project.sh to have run. Skips cleanly if the
# project does not exist yet (early repo state).
# Env:
#   SCHEME (SmartLights)  PROJECT (SmartLights.xcodeproj)  SIM_NAME (optional)
#   ARTIFACTS_DIR (artifacts/)  SPM_CACHE_DIR (.ci/spm)  DERIVED_DATA (.ci/DerivedData)
#   SIM_SIGNING_ARGS  extra signing build settings (default: unsigned simulator build)
. "$(dirname "$0")/lib.sh"

cd "$REPO_ROOT"
scheme="${SCHEME:-SmartLights}"
project="${PROJECT:-SmartLights.xcodeproj}"
out="${ARTIFACTS_DIR:-$REPO_ROOT/artifacts}"
spm="${SPM_CACHE_DIR:-$REPO_ROOT/.ci/spm}"
dd="${DERIVED_DATA:-$REPO_ROOT/.ci/DerivedData}"
mkdir -p "$out" "$spm"

if [ ! -d "$project" ]; then
  warn "$project not found (no project.yml yet?); skipping app build"
  exit 0
fi

# Unsigned simulator build: no Apple account on PR builds, and the HomeKit /
# App Group entitlements must not require a team. Override for keychain-heavy
# tests, e.g. SIM_SIGNING_ARGS="CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO".
read -r -a signing <<< "${SIM_SIGNING_ARGS:-CODE_SIGNING_ALLOWED=NO}"

sim_id="$(bash "$CI_DIR/pick-simulator.sh")"
common=(
  -project "$project" -scheme "$scheme"
  -destination "id=$sim_id"
  -derivedDataPath "$dd"
  -clonedSourcePackagesDirPath "$spm"
  -skipPackagePluginValidation -skipMacroValidation
  "${signing[@]}"
)

group_start "resolve packages"
xcodebuild -resolvePackageDependencies -project "$project" -scheme "$scheme" \
  -clonedSourcePackagesDirPath "$spm"
group_end

group_start "build-for-testing $scheme"
rm -rf "$out/$scheme-build.xcresult"
status=0
xcodebuild build-for-testing "${common[@]}" -resultBundlePath "$out/$scheme-build.xcresult" 2>&1 \
  | tee "$out/$scheme-build.log" || status=$?
group_end
if [ "$status" -ne 0 ]; then
  if grep -q "not currently configured for the test action" "$out/$scheme-build.log"; then
    warn "scheme $scheme has no test action; running a plain build instead"
    rm -rf "$out/$scheme-build.xcresult"
    xcodebuild build "${common[@]}" -resultBundlePath "$out/$scheme-build.xcresult" 2>&1 \
      | tee "$out/$scheme-build.log"
    exit 0
  fi
  die "xcodebuild build-for-testing failed (exit $status); see $scheme-build.xcresult"
fi

group_start "test $scheme"
rm -rf "$out/$scheme-test.xcresult"
status=0
xcodebuild test-without-building "${common[@]}" -resultBundlePath "$out/$scheme-test.xcresult" 2>&1 \
  | tee "$out/$scheme-test.log" || status=$?
group_end
if [ "$status" -ne 0 ]; then
  die "xcodebuild test failed (exit $status); see $scheme-test.xcresult"
fi
log "app build + tests passed"
