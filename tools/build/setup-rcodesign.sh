#!/bin/bash
set -euo pipefail
version=0.29.0
tool_root="${MTV_RCODESIGN_ROOT:-$HOME/Developer/MTVDeveloper/Tools/rcodesign-$version}"
[[ "$(uname -m)" == arm64 ]] || { echo 'This pinned runtime is for Apple Silicon.' >&2; exit 1; }
if [[ -x "$tool_root/rcodesign" ]]; then
  "$tool_root/rcodesign" --version
  exit 0
fi
mkdir -p "$tool_root"
stage="$(mktemp -d "$tool_root/.download.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
asset="apple-codesign-$version-aarch64-apple-darwin.tar.gz"
base="https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign/$version"
curl --fail --location --connect-timeout 10 --max-time 180 "$base/$asset" -o "$stage/runtime.tar.gz"
curl --fail --location --connect-timeout 10 --max-time 30 "$base/$asset.sha256" -o "$stage/runtime.sha256"
expected="$(tr -d '\r\n' < "$stage/runtime.sha256")"
[[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || { echo 'Invalid publisher checksum.' >&2; exit 1; }
observed="$(shasum -a 256 "$stage/runtime.tar.gz" | cut -d ' ' -f 1)"
[[ "$observed" == "$expected" ]] || { echo 'Publisher checksum mismatch.' >&2; exit 1; }
tar -tzf "$stage/runtime.tar.gz" | ruby -e 'STDIN.each_line { |line| p=line.chomp; abort "Unsafe archive entry" if p.start_with?("/") || p.split("/").include?("..") }'
mkdir "$stage/unpacked"
tar -xzf "$stage/runtime.tar.gz" -C "$stage/unpacked"
binary="$(find "$stage/unpacked" -type f -name rcodesign -print)"
[[ -n "$binary" && "$binary" != *$'\n'* ]] || { echo 'Expected exactly one rcodesign executable.' >&2; exit 1; }
cp "$binary" "$tool_root/rcodesign"
chmod 755 "$tool_root/rcodesign"
printf '%s\n' "$base/$asset" > "$tool_root/SOURCE.txt"
"$tool_root/rcodesign" --version
