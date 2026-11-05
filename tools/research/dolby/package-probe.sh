#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
destination="$PWD/.build/ProbeRuntime"
mkdir -p "$destination"
cp "$binary_dir/MTVDolbyProbe" "$destination/"
for framework in "$binary_dir"/*.framework; do
  ditto "$framework" "$destination/$(basename "$framework")"
  chmod -R u+w "$destination/$(basename "$framework")"
  codesign --force --sign - "$destination/$(basename "$framework")"
done
for resource in "$binary_dir"/*.bundle; do
  [[ -d "$resource" ]] || continue
  ditto "$resource" "$destination/$(basename "$resource")"
done
codesign --force --sign - "$destination/MTVDolbyProbe"
printf 'Isolated runtime: %s\n' "$destination"
