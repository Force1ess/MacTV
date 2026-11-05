#!/bin/bash
set -euo pipefail
encoder="${MTV_TEST_FFMPEG:?Set MTV_TEST_FFMPEG to an existing ffmpeg executable}"
webp_encoder="${MTV_TEST_CWEBP:?Set MTV_TEST_CWEBP to an existing cwebp executable}"
fixture_root="${MTV_TEST_FIXTURES:?Set MTV_TEST_FIXTURES to an MTV-owned fixture directory}"
[[ -x "$encoder" && -x "$webp_encoder" ]] || { echo 'Test encoders not executable' >&2; exit 1; }
mkdir -p "$fixture_root"
if [[ ! -e "$fixture_root/blue.png" ]]; then
  "$encoder" -hide_banner -loglevel error -f lavfi -i color=c=blue:s=96x144 -frames:v 1 -c:v png -update 1 -n "$fixture_root/blue.png"
fi
if [[ ! -e "$fixture_root/blue.webp" ]]; then
  "$webp_encoder" -quiet -lossless "$fixture_root/blue.png" -o "$fixture_root/blue.webp"
fi
printf 'Generated-only artwork format fixture: %s\n' "$fixture_root/blue.webp"
