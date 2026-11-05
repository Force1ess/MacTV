#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
version=1.5.0
url="https://github.com/iina/iina/releases/download/v$version/IINA.v$version.dmg"
expected=8fad50479b10e09645053457cec46bd53d054ced2242cfe68f74586735a20dc7
mkdir -p .build/vendor-downloads Vendor .build/vendor-backups
archive="${MTV_MPV_IINA_DMG:-$PWD/.build/vendor-downloads/IINA.v$version.dmg}"
if [[ ! -f "$archive" ]]; then
  curl --fail --location --retry 2 --connect-timeout 20 --max-time 300 "$url" -o "$archive.partial"
  mv "$archive.partial" "$archive"
fi
actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || { echo 'Official archive checksum mismatch' >&2; exit 1; }
mount="$PWD/.build/mpv-iina-$version-mount"
mkdir -p "$mount"
trap 'hdiutil detach -quiet "$mount" 2>/dev/null || true; rmdir "$mount" 2>/dev/null || true' EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$archive" >/dev/null
source_app="$mount/IINA.app"
codesign --verify --deep --strict "$source_app"
stage="$(mktemp -d "$PWD/.build/mpv-engine.XXXXXX")"
mkdir -p "$stage/MPVEngine/lib" "$stage/MPVEngine/licenses"
for library in "$source_app/Contents/Frameworks/"*.dylib; do
  cp -p "$library" "$stage/MPVEngine/lib/"
done
[[ -f "$stage/MPVEngine/lib/libmpv.2.dylib" ]] || { echo 'Missing official libmpv' >&2; exit 1; }
find "$source_app/Contents/Resources" -iname '*license*' -o -iname '*copying*' > "$stage/MPVEngine/licenses/official-resource-paths.txt"
for name in LICENSE.txt LICENSE COPYING; do
  [[ ! -f "$source_app/Contents/Resources/$name" ]] || cp "$source_app/Contents/Resources/$name" "$stage/MPVEngine/licenses/"
done
printf 'Paired mpv runtime from official IINA %s.\nArchive: %s\nSHA256: %s\nSource: https://github.com/iina/iina/tree/v%s\nmpv source: https://github.com/mpv-player/mpv\nPrivate evaluation; do not publish before corresponding-source/license review.\n' "$version" "$url" "$expected" "$version" > "$stage/MPVEngine/SOURCE.txt"
if [[ -d vendor/MPVEngine ]]; then mv vendor/MPVEngine ".build/vendor-backups/MPVEngine-$(date +%Y%m%d-%H%M%S)-$$"; fi
mv "$stage/MPVEngine" vendor/MPVEngine
printf 'Prepared private mpv runtime: %s/vendor/MPVEngine\n' "$PWD"
