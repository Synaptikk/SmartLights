#!/usr/bin/env bash
# Lists the Swift packages that must build and test on Linux (swift Docker image).
#
# A package under Packages/ is Linux-tested when ANY of these holds:
#   * its directory contains a file named LINUX_OK   (the explicit opt-in;
#     every Packages/Providers/<Brand>Kit with a codec must have one)
#   * its directory name ends in "Codec"             (e.g. Packages/Foo/BarCodec)
#   * its directory name is "LightCore"
# ...unless its directory contains a file named LINUX_SKIP (escape hatch).
#
# Output: --json (default) prints a compact JSON array for a GitHub matrix,
#         e.g. ["Packages/LightCore","Packages/Providers/WiZKit"];
#         --lines prints one path per line.
. "$(dirname "$0")/lib.sh"

mode="${1:---json}"
selected=()
while IFS= read -r dir; do
  [ -n "$dir" ] || continue
  name="$(basename "$dir")"
  if [ -f "$REPO_ROOT/$dir/LINUX_SKIP" ]; then
    log "skip (LINUX_SKIP): $dir"
    continue
  fi
  if [ -f "$REPO_ROOT/$dir/LINUX_OK" ] || [[ "$name" == *Codec ]] || [ "$name" = "LightCore" ]; then
    selected+=("$dir")
  fi
done < <(list_packages)

case "$mode" in
  --lines)
    for d in ${selected[@]+"${selected[@]}"}; do printf '%s\n' "$d"; done ;;
  --json)
    out="["; sep=""
    for d in ${selected[@]+"${selected[@]}"}; do out+="$sep\"$d\""; sep=","; done
    printf '%s]\n' "$out" ;;
  *) die "usage: $0 [--json|--lines]" ;;
esac
