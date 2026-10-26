#!/usr/bin/env bash
# Prints the UDID of an available iPhone simulator on this runner.
# Prefers SIM_NAME (e.g. "iPhone 17") if set and present; otherwise the first
# numbered iPhone ("iPhone 17") on the newest iOS runtime that has one, else
# any iPhone. Simulator names change
# with every runner image, so never hard-code a device name in workflows.
# Usage: SIM_ID="$(tools/ci/pick-simulator.sh)"
. "$(dirname "$0")/lib.sh"

json="$(xcrun simctl list devices available --json)"
want="${SIM_NAME:-}"

pick() {
  # $1 = jq filter on device name. Runtimes sorted newest first.
  printf '%s' "$json" | jq -r --arg want "$want" '
    .devices
    | to_entries
    | map(select(.key | contains("SimRuntime.iOS-")))
    | map(.v = (.key | capture("iOS-(?<maj>[0-9]+)-(?<min>[0-9]+)") | [(.maj|tonumber),(.min|tonumber)]))
    | sort_by(.v) | reverse
    | map(.value[] | select(.isAvailable != false) | select('"$1"'))
    | first | .udid // empty'
}

udid=""
if [ -n "$want" ]; then udid="$(pick '.name == $want')"; fi
if [ -z "$udid" ]; then
  [ -z "$want" ] || warn "simulator '$want' not found; picking another iPhone"
  # Plain numbered iPhones first (most representative), then any iPhone.
  udid="$(pick '.name | test("^iPhone [0-9]+$")')"
  [ -n "$udid" ] || udid="$(pick '.name | startswith("iPhone")')"
fi
if [ -z "$udid" ]; then
  xcrun simctl list devices available >&2
  die "no available iPhone simulator on this runner"
fi
name="$(printf '%s' "$json" | jq -r --arg u "$udid" '.devices[][] | select(.udid == $u) | .name')"
log "simulator: $name ($udid)"
printf '%s\n' "$udid"
