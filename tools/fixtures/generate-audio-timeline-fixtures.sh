#!/bin/bash
set -euo pipefail
encoder="${MTV_TEST_FFMPEG:?Use the existing test encoder}"
root="${MTV_TEST_AUDIO_TIMELINE:?Use a new MTV-owned fixture directory}"
[[ -x "$encoder" ]] || exit 1
mkdir -p "$root"
for index in 0 1 2 3; do
  target="$root/Segment-$index.mp4"
  if [[ ! -e "$target" ]]; then
    base=$((400 + index * 300))
    "$encoder" -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=30 \
      -f lavfi -i "aevalsrc=0.15*sin(2*PI*($base*t+12.5*t*t)):s=48000" -t 12 \
      -c:v libx264 -preset veryfast -g 250 -pix_fmt yuv420p -c:a aac -movflags +faststart -n "$target"
  fi
done
printf 'Owned audio/video timeline segments: %s\n' "$root"
