#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
cache="${MTV_RIME_DOWNLOADS:-$PWD/.build/rime-downloads}"
mkdir -p "$cache" "$PWD/.build"
fetch() {
  if [[ ! -s "$cache/$1" ]]; then
    curl --fail --silent --show-error --location --connect-timeout 10 --max-time 180 "$2" -o "$cache/$1.partial"
    mv "$cache/$1.partial" "$cache/$1"
  fi
}
base="https://github.com/rime/librime/releases/download/1.17.0"
fetch rime.tar.bz2 "$base/rime-33e7814-macOS-universal.tar.bz2"
fetch deps.tar.bz2 "$base/rime-deps-33e7814-macOS-universal.tar.bz2"
[[ "$(shasum -a 256 "$cache/rime.tar.bz2" | awk '{print $1}')" == 11d8dc663c6ec06d5ccb6111ba664a9e7b631b703ac6acd07cffbac664021850 ]] || { echo 'Rime release digest mismatch' >&2; exit 1; }
[[ "$(shasum -a 256 "$cache/deps.tar.bz2" | awk '{print $1}')" == dfe6047e87be271963d7466bd1a6e3d9e660c30e5e73e4bb94e8782c0a6ac8df ]] || { echo 'Rime dependency release digest mismatch' >&2; exit 1; }
fetch luna.tar.gz https://codeload.github.com/rime/rime-luna-pinyin/tar.gz/56b934b099dfbeab842320f13aa8b461a6ab3e42
fetch prelude.tar.gz https://codeload.github.com/rime/rime-prelude/tar.gz/082425ea0684bca36474415d4a0e8db9b016487e
fetch stroke.tar.gz https://codeload.github.com/rime/rime-stroke/tar.gz/1e8fff9b9494ddec23b0cbc526bcfd8171a6fd48
fetch essay.tar.gz https://codeload.github.com/rime/rime-essay/tar.gz/054920de4f54c9e5994276a96a4fc2a35cb51aa3
stage="$(mktemp -d "$PWD/.build/rime-stage.XXXXXX")"
mkdir -p "$stage/engine/lib" "$stage/engine/share" "$stage/engine/licenses" "$stage/deps"
tar -xjf "$cache/rime.tar.bz2" -C "$stage"
tar -xjf "$cache/deps.tar.bz2" -C "$stage/deps"
cp "$stage/dist/lib/librime.1.17.0.dylib" "$stage/engine/lib/"
cp -R "$stage/deps/share/opencc" "$stage/engine/share/"
for scheme in luna prelude stroke essay; do
  mkdir "$stage/$scheme"
  tar -xzf "$cache/$scheme.tar.gz" --strip-components=1 -C "$stage/$scheme"
  cp "$stage/$scheme/LICENSE" "$stage/engine/licenses/$scheme-LICENSE"
  cp "$stage/$scheme/AUTHORS" "$stage/engine/licenses/$scheme-AUTHORS"
  cp "$stage/$scheme/README.md" "$stage/engine/licenses/$scheme-README.md"
  for data in "$stage/$scheme/"*.yaml "$stage/$scheme/essay.txt"; do
    [[ ! -f "$data" ]] || cp "$data" "$stage/engine/share/"
  done
done
cp resources/rime/*.yaml "$stage/engine/share/"
cp src/Sources/RimeBridge/upstream/LICENSE "$stage/engine/licenses/librime-BSD"
ruby -r./tools/build/native-runtime-materials.rb -e 'puts JSON.generate(NativeRuntimeMaterials.notice_inventory(ARGV.fetch(0)))' resources/rime/third-party
cp -R resources/rime/third-party "$stage/engine/licenses/static-dependencies"
cp "$stage/version-info.txt" "$stage/engine/licenses/upstream-version-info.txt"
cat > "$stage/engine/SOURCE.txt" <<'EOF'
librime 1.17.0 official universal macOS binary, release commit 33e7814.
Release: https://github.com/rime/librime/releases/tag/1.17.0
Archive sha256: 11d8dc663c6ec06d5ccb6111ba664a9e7b631b703ac6acd07cffbac664021850
Deps sha256: dfe6047e87be271963d7466bd1a6e3d9e660c30e5e73e4bb94e8782c0a6ac8df
Schemas: rime-luna-pinyin 56b934b099dfbeab842320f13aa8b461a6ab3e42
Prelude: 082425ea0684bca36474415d4a0e8db9b016487e
Stroke: 1e8fff9b9494ddec23b0cbc526bcfd8171a6fd48
Essay: 054920de4f54c9e5994276a96a4fc2a35cb51aa3
Original LGPL data sources, AUTHORS and licenses retained. MTV custom patches are in resources/rime.
No librime Lua/predict/octagram plugins are shipped. OpenCC data comes from the same official dependency release.
Private development package: complete static dependency notices and data attribution audit remain required before public binary distribution.
EOF
mkdir -p Vendor .build/vendor-backups
if [[ -d vendor/RimeEngine ]]; then mv vendor/RimeEngine ".build/vendor-backups/RimeEngine-$(date +%Y%m%d-%H%M%S)-$$"; fi
mv "$stage/engine" vendor/RimeEngine
# Retain downloaded/extracted source for dependency inspection; never remove user data.
printf 'Prepared Rime engine: %s/vendor/RimeEngine\nRetained source stage: %s\n' "$PWD" "$stage"
