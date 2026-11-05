#!/bin/bash
set -euo pipefail
encoder="${MTV_TEST_FFMPEG:?Set MTV_TEST_FFMPEG to an existing ffmpeg executable}"
fixture_root="${MTV_TEST_FIXTURES:?Set MTV_TEST_FIXTURES to an MTV-owned generated-fixture directory}"
[[ -x "$encoder" ]] || { echo 'ffmpeg not executable' >&2; exit 1; }
mkdir -p "$fixture_root"
target="$fixture_root/IndependentLongGOP45-v1.mp4"
if [[ ! -e "$target" ]]; then
  "$encoder" -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=30 \
    -f lavfi -i sine=frequency=440:sample_rate=48000 -t 45 -c:v libx264 -preset veryfast \
    -g 300 -keyint_min 300 -sc_threshold 0 -pix_fmt yuv420p -c:a aac -movflags +faststart -n "$target"
fi
printf 'Generated-only long GOP fixture: %s\n' "$target"
