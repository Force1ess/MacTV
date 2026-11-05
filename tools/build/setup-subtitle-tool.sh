#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
project="$PWD"
compiler="$(xcrun --find clang)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
version=n8.1.2
url="https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/tags/$version"
mkdir -p .build/subtitle-tool-downloads
archive="${MTV_SUBTITLE_SOURCE_ARCHIVE:-$PWD/.build/subtitle-tool-downloads/ffmpeg-$version.tar.gz}"
if [[ ! -f "$archive" ]]; then
  partial="$(mktemp "$PWD/.build/subtitle-tool-downloads/source.XXXXXX")"
  if ! curl --fail --silent --show-error --location --max-time 180 "$url" -o "$partial"; then rm -f "$partial"; exit 1; fi
  tar -tzf "$partial" >/dev/null
  mv "$partial" "$archive"
fi
archive="$(cd "$(dirname "$archive")" && pwd)/$(basename "$archive")"
stage="$(mktemp -d "$PWD/.build/subtitle-tool-build.XXXXXX")"
mkdir "$stage/source"
tar -xzf "$archive" --strip-components=1 -C "$stage/source"
cd "$stage/source"
./configure --disable-everything --disable-autodetect --disable-network \
  --cc="$compiler" --sysroot="$sdk" \
  --host-cflags="--sysroot=$sdk -mmacosx-version-min=15.0" \
  --host-ldflags="--sysroot=$sdk -mmacosx-version-min=15.0" \
  --disable-gpl --disable-nonfree --disable-version3 --disable-asm \
  --disable-shared --enable-static --disable-debug --disable-doc --enable-small \
  --disable-avdevice --disable-swscale --disable-swresample \
  --disable-ffplay --disable-ffprobe --enable-ffmpeg \
  --enable-demuxer=webvtt --enable-decoder=webvtt --enable-encoder=ass \
  --enable-muxer=ass --enable-protocol=pipe \
  --extra-cflags=-mmacosx-version-min=15.0 --extra-ldflags=-mmacosx-version-min=15.0
make -j4 ffmpeg
tool="$stage/SubtitleTool"
mkdir -p "$tool/licenses" "$tool/source"
cp ffmpeg "$tool/ffmpeg"
cp COPYING.LGPLv2.1 LICENSE.md "$tool/licenses/"
cp "$archive" "$tool/source/ffmpeg-$version.tar.gz"
cp "$project/tools/build/setup-subtitle-tool.sh" "$tool/source/build.sh"
./ffmpeg -hide_banner -buildconf > "$tool/build-config.txt" 2>&1
./ffmpeg -hide_banner -protocols > "$tool/protocols.txt" 2>&1
otool -L "$tool/ffmpeg" > "$tool/system-libraries.txt"
printf 'FFmpeg %s, official FFmpeg/FFmpeg source mirror.\nSource: %s\nNo source modifications. Minimal WebVTT to ASS converter; network and file protocols disabled.\nLGPL 2.1 or later; original license and corresponding source included.\n' "$version" "$url" > "$tool/SOURCE.txt"
shasum -a 256 "$archive" >> "$tool/SOURCE.txt"
cd "$project"
mkdir -p Vendor .build/vendor-backups
if [[ -d vendor/SubtitleTool ]]; then mv vendor/SubtitleTool ".build/vendor-backups/SubtitleTool-$(date +%Y%m%d-%H%M%S)-$$"; fi
mv "$tool" vendor/SubtitleTool
printf 'Prepared subtitle-only tool: %s/vendor/SubtitleTool\n' "$PWD"
