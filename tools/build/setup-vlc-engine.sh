#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ "$(uname -m)" == arm64 ]] || { echo 'This private engine package currently targets Apple Silicon only' >&2; exit 1; }
version="3.0.23"
cache="$PWD/.build/vendor-downloads"
mkdir -p "$cache"
archive="${MTV_VLC_DMG:-$cache/vlc-$version-arm64.dmg}"
base="https://download.videolan.org/vlc/$version/macosx"
if [[ ! -f "$archive" ]]; then
  curl --fail --silent --show-error --location --max-time 180 "$base/vlc-$version-arm64.dmg" -o "$archive"
fi
expected="$(curl --fail --silent --show-error --location --max-time 30 "$base/vlc-$version-arm64.dmg.sha256" | awk '{print $1}')"
actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$expected" == "$actual" ]] || { echo 'Official VLC archive checksum mismatch' >&2; exit 1; }
task_mount="$(mktemp -d /tmp/mtv-vlc-engine.XXXXXX)"
trap 'hdiutil detach -quiet "$task_mount" 2>/dev/null || true; rmdir "$task_mount" 2>/dev/null || true' EXIT
if ! hdiutil attach -nobrowse -readonly -mountpoint "$task_mount" "$archive" >/dev/null; then
  echo 'Cannot mount VLC archive (it may already be mounted); no engine was installed' >&2
  exit 1
fi
source_app="$task_mount/VLC.app"
codesign --verify --deep --strict "$source_app"
stage="$(mktemp -d "$PWD/.build/vlc-engine-stage.XXXXXX")"
engine="$stage/VLCEngine"
mkdir -p "$engine/licenses"
ditto "$source_app/Contents/MacOS/lib" "$engine/lib"
ditto "$source_app/Contents/MacOS/plugins" "$engine/plugins"
ditto "$source_app/Contents/MacOS/share" "$engine/share"
for license in COPYING COPYING.LIB; do
  curl --fail --silent --show-error --location --max-time 30 "https://raw.githubusercontent.com/videolan/vlc/3.0.x/$license" -o "$engine/licenses/$license"
done
printf 'VLC %s (Apple Silicon)\nOfficial archive: %s/vlc-%s-arm64.dmg\nSHA256: %s\nUnmodified vendor-signed libraries and modules.\nlibVLC has LGPL terms; bundled modules have additional GPL/third-party terms.\nPrivate development integration only; public distribution requires a complete dependency/source/license audit.\n' "$version" "$base" "$version" "$actual" > "$engine/SOURCE.txt"
mkdir -p "$PWD/Vendor"
if [[ -d "$PWD/vendor/VLCEngine" ]]; then
  mkdir -p "$PWD/.build/vendor-backups"
  mv "$PWD/vendor/VLCEngine" "$PWD/.build/vendor-backups/VLCEngine-$(date +%Y%m%d-%H%M%S)-$$"
fi
mv "$engine" "$PWD/vendor/VLCEngine"
rmdir "$stage"
engine="$PWD/vendor/VLCEngine"
printf 'Prepared private playback engine: %s\n' "$engine"
