#!/usr/bin/env bash
# Archives SmartLights with automatic signing (App Store Connect API key) and
# either uploads it to App Store Connect / TestFlight or exports an .ipa.
#
# Required env (GitHub secrets, see docs/BUILD.md "CI and TestFlight"):
#   ASC_KEY_ID      App Store Connect API key id (10 chars)
#   ASC_ISSUER_ID   issuer UUID shown above the key list
#   ASC_KEY_P8      the AuthKey_<id>.p8 file, base64-encoded
#   APPLE_TEAM_ID   10-char Developer Team ID
# Optional env:
#   EXPORT_METHOD   app-store-connect (default) | release-testing (ad hoc) | debugging
#   UPLOAD          true (default for app-store-connect) | false (export .ipa only)
#   UPLOAD_TOOL     xcodebuild (default) | altool
#   MARKETING_VERSION  default: from tag vX.Y.Z (GITHUB_REF_NAME), else project value
#   BUILD_NUMBER    default: <run number>.<run attempt> (e.g. 42.1), else UTC timestamp
#   DEV_CERT_P12 / DEV_CERT_PASSWORD  optional Apple Development identity (base64 .p12)
#   CODE_SIGN_ENTITLEMENTS  e.g. App/SmartLights.multicast.entitlements once granted
#   SCHEME (SmartLights) PROJECT (SmartLights.xcodeproj) ARTIFACTS_DIR (artifacts/)
. "$(dirname "$0")/lib.sh"

: "${ASC_KEY_ID:?ASC_KEY_ID secret missing}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID secret missing}"
: "${ASC_KEY_P8:?ASC_KEY_P8 secret missing}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID secret missing}"

cd "$REPO_ROOT"
scheme="${SCHEME:-SmartLights}"
project="${PROJECT:-SmartLights.xcodeproj}"
out="${ARTIFACTS_DIR:-$REPO_ROOT/artifacts}"
method="${EXPORT_METHOD:-app-store-connect}"
upload="${UPLOAD:-true}"
tool="${UPLOAD_TOOL:-xcodebuild}"
[ "$method" = "app-store-connect" ] || upload=false   # only App Store builds go to TestFlight
mkdir -p "$out"
[ -d "$project" ] || die "$project not found; run tools/ci/generate-project.sh first"

# --- versions -----------------------------------------------------------------
ref="${GITHUB_REF_NAME:-}"
version="${MARKETING_VERSION:-}"
if [ -z "$version" ] && [[ "$ref" =~ ^v([0-9]+(\.[0-9]+){0,2})$ ]]; then version="${BASH_REMATCH[1]}"; fi
if [ -n "${BUILD_NUMBER:-}" ]; then build="$BUILD_NUMBER"
elif [ -n "${GITHUB_RUN_NUMBER:-}" ]; then build="$GITHUB_RUN_NUMBER.${GITHUB_RUN_ATTEMPT:-1}"   # re-runs stay unique
else build="$(date -u +%Y%m%d%H%M)"; fi
version_args=(CURRENT_PROJECT_VERSION="$build")
[ -z "$version" ] || version_args+=(MARKETING_VERSION="$version")
log "version ${version:-<project default>} build $build, export method $method, upload $upload ($tool)"

# --- API key ------------------------------------------------------------------
tmp="${RUNNER_TEMP:-$(mktemp -d)}"
key_dir="$HOME/.appstoreconnect/private_keys"     # where altool looks for keys
mkdir -p "$key_dir"
key_path="$key_dir/AuthKey_${ASC_KEY_ID}.p8"
printf '%s' "$ASC_KEY_P8" | base64 --decode > "$key_path"
chmod 600 "$key_path"
grep -q "BEGIN PRIVATE KEY" "$key_path" || die "ASC_KEY_P8 is not a base64-encoded .p8 file"
auth=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$key_path"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
)

# --- throwaway keychain -------------------------------------------------------
# Automatic signing may create/download a signing certificate; keep it in a
# keychain that dies with the runner and never prompts.
keychain="$tmp/smartlights-ci.keychain-db"
kc_pass="$(uuidgen)"
security create-keychain -p "$kc_pass" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$kc_pass" "$keychain"
# shellcheck disable=SC2046
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
security default-keychain -d user -s "$keychain"
cleanup() {
  security delete-keychain "$keychain" 2>/dev/null || true
  rm -f "$key_path"
}
trap cleanup EXIT

# Archiving with automatic signing needs an Apple Development identity. Without
# one, -allowProvisioningUpdates makes Xcode create a new "Created via API"
# development certificate on every run (they pile up). Supplying one .p12 via
# DEV_CERT_P12 / DEV_CERT_PASSWORD reuses it. The App Store export is signed
# with Apple's cloud-managed distribution certificate either way.
if [ -n "${DEV_CERT_P12:-}" ]; then
  printf '%s' "$DEV_CERT_P12" | base64 --decode > "$tmp/dist.p12"
  security import "$tmp/dist.p12" -k "$keychain" -P "${DEV_CERT_PASSWORD:-}" \
    -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild
  security set-key-partition-list -S apple-tool:,apple: -s -k "$kc_pass" "$keychain" >/dev/null
  rm -f "$tmp/dist.p12"
  log "imported development identity from DEV_CERT_P12"
fi

ent_args=()
[ -z "${CODE_SIGN_ENTITLEMENTS:-}" ] || ent_args+=(CODE_SIGN_ENTITLEMENTS="$CODE_SIGN_ENTITLEMENTS")

# --- archive ------------------------------------------------------------------
archive="$out/$scheme.xcarchive"
rm -rf "$archive"
group_start "archive"
xcodebuild archive \
  -project "$project" -scheme "$scheme" -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive" \
  -skipPackagePluginValidation -skipMacroValidation \
  "${auth[@]}" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CODE_SIGN_STYLE=Automatic \
  "${version_args[@]}" ${ent_args[@]+"${ent_args[@]}"} 2>&1 | tee "$out/archive.log"
group_end

# --- export / upload ----------------------------------------------------------
destination="export"
if [ "$upload" = "true" ] && [ "$tool" = "xcodebuild" ]; then destination="upload"; fi
plist="$tmp/ExportOptions.plist"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>$method</string>
  <key>destination</key><string>$destination</string>
  <key>teamID</key><string>$APPLE_TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>testFlightInternalTestingOnly</key><false/>
</dict>
</plist>
PLIST

export_dir="$out/export"
rm -rf "$export_dir"
group_start "exportArchive (destination=$destination)"
xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportOptionsPlist "$plist" \
  -exportPath "$export_dir" \
  "${auth[@]}" 2>&1 | tee "$out/export.log"
group_end

if [ "$upload" = "true" ] && [ "$tool" = "altool" ]; then
  ipa="$(ls "$export_dir"/*.ipa | head -1)"
  group_start "altool --upload-app $ipa"
  # altool from Xcode 26+ has been reported to exit 0 on failed uploads, so the
  # output is checked as well.
  xcrun altool --upload-app -f "$ipa" -t ios \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --output-format json 2>&1 | tee "$out/altool.log"
  group_end
  if grep -qE '"product-errors"|ERROR ITMS-' "$out/altool.log"; then die "altool upload failed"; fi
fi

if [ "$upload" = "true" ]; then
  log "uploaded build $build to App Store Connect; it appears in TestFlight after processing (5-30 min)"
else
  log "exported to $export_dir"
fi
