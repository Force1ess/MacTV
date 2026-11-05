#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
encoder="${MTV_TEST_FFMPEG:?Set MTV_TEST_FFMPEG to an existing ffmpeg executable}"
fixture_root="${MTV_TEST_FIXTURES:?Set MTV_TEST_FIXTURES to MTV-owned generated-fixture directory}"
[[ -x "$encoder" ]] || { echo 'ffmpeg not executable' >&2; exit 1; }
mkdir -p "$fixture_root"
base="$fixture_root/h264-aac.mp4"
if [[ ! -e "$base" ]]; then
  "$encoder" -hide_banner -loglevel error -f lavfi -i testsrc2=size=1280x720:rate=30 \
    -f lavfi -i sine=frequency=440:sample_rate=48000 -t 10 -c:v libx264 -preset veryfast \
    -pix_fmt yuv420p -c:a aac -movflags +faststart -n "$base"
fi
if [[ ! -e "$fixture_root/h264-aac.mkv" ]]; then
  "$encoder" -hide_banner -loglevel error -i "$base" -map 0 -c copy -n "$fixture_root/h264-aac.mkv"
fi
if [[ ! -e "$fixture_root/hevc-aac.mp4" ]]; then
  "$encoder" -hide_banner -loglevel error -i "$base" -c:v libx265 -preset ultrafast \
    -x265-params log-level=error:pools=2 -tag:v hvc1 -c:a copy -movflags +faststart -n "$fixture_root/hevc-aac.mp4"
fi
if [[ ! -e "$fixture_root/h264-eac3.mp4" ]]; then
  "$encoder" -hide_banner -loglevel error -i "$base" -c:v copy -c:a eac3 -b:a 192k \
    -movflags +faststart -n "$fixture_root/h264-eac3.mp4"
fi
if [[ ! -e "$fixture_root/h264-subtitles.mp4" ]]; then
  "$encoder" -hide_banner -loglevel error -i "$base" -i src/Tests/Fixtures/subtitles/test.srt \
    -map 0 -map 1 -c copy -c:s mov_text -metadata:s:s:0 language=eng \
    -movflags +faststart -n "$fixture_root/h264-subtitles.mp4"
fi
if [[ ! -e "$fixture_root/h264-two-subtitles.mp4" ]]; then
  "$encoder" -hide_banner -loglevel error -i "$base" -i src/Tests/Fixtures/subtitles/test.srt -i src/Tests/Fixtures/subtitles/test.srt \
    -map 0 -map 1 -map 2 -c copy -c:s mov_text -metadata:s:s:0 language=eng -metadata:s:s:1 language=zho \
    -disposition:s:0 0 -disposition:s:1 0 -movflags +faststart -n "$fixture_root/h264-two-subtitles.mp4"
fi
if [[ ! -e "$fixture_root/h264-two-audio.mp4" ]]; then
  "$encoder" -hide_banner -loglevel error -i "$base" -f lavfi -i sine=frequency=880:sample_rate=48000 \
    -map 0:v -map 0:a -map 1:a -t 10 -c:v copy -c:a aac \
    -metadata:s:a:0 language=eng -metadata:s:a:1 language=zho \
    -movflags +faststart -n "$fixture_root/h264-two-audio.mp4"
fi
printf 'Generated fixtures (no original media modified): %s\n' "$fixture_root"
