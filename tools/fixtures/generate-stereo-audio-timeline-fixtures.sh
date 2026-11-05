#!/bin/bash
set -euo pipefail
encoder="${MTV_TEST_FFMPEG:?Use the existing test encoder}"
root="${MTV_TEST_STEREO_TIMELINE:?Use a new MTV-owned fixture directory}"
[[ -x "$encoder" && "$(basename "$root")" == stereo-audio-timeline-fixtures-v1 ]] || exit 1
mkdir -p "$root"
for index in 0 1 2 3; do
  target="$root/Segment-$index.mp4"
  if [[ ! -e "$target" ]]; then
    left=$((400 + index * 300))
    right=$((1000 + index * 180))
    "$encoder" -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=30 \
      -f lavfi -i "aevalsrc=0.12*sin(2*PI*($left*t+12.5*t*t))|0.08*sin(2*PI*($right*t+7.5*t*t)):s=44100:c=stereo" \
      -t 12 -c:v libx264 -preset veryfast -g 250 -pix_fmt yuv420p -c:a aac -b:a 192k -ar 44100 -ac 2 \
      -movflags +faststart -n "$target"
  fi
done
printf 'Owned 44.1 kHz stereo timeline segments: %s\n' "$root"
