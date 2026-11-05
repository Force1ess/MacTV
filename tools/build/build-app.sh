#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
ruby tools/build/preview-artifacts.rb --configured --apply
signing_identity="${MTV_CODESIGN_IDENTITY:--}"
file_signing="${MTV_FILE_SIGNING:-auto}"
if [[ "$file_signing" == 1 && -n "${MTV_CODESIGN_IDENTITY:-}" ]]; then
  echo 'Choose file signing or a keychain signing identity, not both.' >&2; exit 1
fi
if [[ "$file_signing" == auto && -z "${MTV_CODESIGN_IDENTITY:-}" ]]; then
  file_status=0
  ruby tools/build/file-signing.rb configured || file_status=$?
  if [[ "$file_status" == 0 ]]; then file_signing=1
  elif [[ "$file_status" != 1 ]]; then exit "$file_status"
  fi
fi
if [[ "$file_signing" == 1 ]]; then
  echo 'Building with the existing file-based local preview identity.' >&2
elif [[ "$signing_identity" == '-' ]]; then
  echo 'Building an ad-hoc development app. Routine installation requires the existing signing identity to match.' >&2
fi
# Ask SwiftPM for its output directory: Swift 7 defaults to swiftbuild, whose
# layout differs from the older native engine. Honor an explicit build SDK.
swift_arguments=(-c release)
if [[ -n "${SDKROOT:-}" ]]; then swift_arguments+=(--sdk "$SDKROOT"); fi
swift build "${swift_arguments[@]}"
bin_directory="$(swift build "${swift_arguments[@]}" --show-bin-path)"
mkdir -p "$PWD/dist"
stage="$(mktemp -d "$PWD/dist/build.XXXXXX")"
app="$stage/MacTV.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp config/plugin-sources.json "$app/Contents/Resources/plugin-sources.json"
cp LICENSE "$app/Contents/Resources/MacTV-LICENSE.txt"
cp "$bin_directory/MTV" "$bin_directory/MTVPluginHost" "$app/Contents/MacOS/"
cp "$bin_directory/MTVChromeBridge" "$app/Contents/MacOS/"
cp "$bin_directory/mtvctl" "$app/Contents/MacOS/"
music_helper="$app/Contents/Helpers/MacTVMusicLibrary.app"
mkdir -p "$music_helper/Contents/MacOS"
cp "$bin_directory/MacTVMusicLibrary" "$music_helper/Contents/MacOS/"
cp config/MusicLibrary-Info.plist "$music_helper/Contents/Info.plist"
codesign --force --sign "$signing_identity" "$music_helper"
codesign --force --sign "$signing_identity" "$app/Contents/MacOS/mtvctl"
ditto "$PWD/src/browser-extension" "$app/Contents/Resources/ChromeQuarkBridge"
provider_artwork="${MTV_INCLUDE_LOCAL_PROVIDER_ARTWORK:-0}"
[[ "$provider_artwork" == 0 || "$provider_artwork" == 1 ]] || { echo 'MTV_INCLUDE_LOCAL_PROVIDER_ARTWORK must be 0 or 1' >&2; exit 1; }
mkdir -p "$app/Contents/Resources/BrandIcons"
cp resources/brand-icons/SOURCES.md "$app/Contents/Resources/BrandIcons/SOURCES.md"
if [[ "$provider_artwork" == 1 ]]; then
  # Explicit local preview only. Native manifest symbols work without these assets.
  ditto "$PWD/resources/brand-icons" "$app/Contents/Resources/BrandIcons"
  echo 'Local provider artwork included; review its rights before redistributing this app.' >&2
fi
ditto "$PWD/resources/attribution" "$app/Contents/Resources/Attribution"
codesign --force --sign "$signing_identity" "$app/Contents/MacOS/MTVChromeBridge"
helper="$app/Contents/Helpers/MTVPluginHost.app"
mkdir -p "$helper/Contents/MacOS"
cp "$bin_directory/MTVPluginHost" "$helper/Contents/MacOS/MTVPluginHost"
cp config/PluginHost-Info.plist "$helper/Contents/Info.plist"
codesign --force --sign "$signing_identity" --identifier local.mtv.plugin-host --entitlements config/PluginHost.entitlements "$helper"
codesign --verify --strict "$helper"
rsync -a src/integrations/ "$app/Contents/Resources/plugins/"

for required in lib/librime.1.17.0.dylib share/luna_pinyin.dict.yaml share/essay.txt share/opencc/t2s.json SOURCE.txt licenses/librime-BSD; do
  [[ -f "$PWD/vendor/RimeEngine/$required" ]] || { echo "Missing input engine resource: $required (run tools/build/setup-rime-engine.sh)" >&2; exit 1; }
done
ditto "$PWD/vendor/RimeEngine" "$app/Contents/Resources/RimeEngine"
ruby -r./tools/build/native-runtime-materials.rb -e 'puts JSON.generate(NativeRuntimeMaterials.notice_inventory(ARGV.fetch(0)))' resources/rime/third-party
ditto "$PWD/resources/rime/third-party" "$app/Contents/Resources/RimeEngine/licenses/static-dependencies"
if [[ "${MTV_INCLUDE_LEGACY_VLC:-0}" == 1 && -d "$PWD/vendor/VLCEngine" ]]; then
  for required in lib/libvlc.dylib plugins/plugins.dat licenses/COPYING licenses/COPYING.LIB SOURCE.txt; do
    [[ -f "$PWD/vendor/VLCEngine/$required" ]] || { echo "Incomplete engine package: $required" >&2; exit 1; }
  done
  ditto "$PWD/vendor/VLCEngine" "$app/Contents/Resources/VLCEngine"
fi
if [[ -d "$PWD/vendor/MPVNativeEngine" ]]; then
  [[ -f "$PWD/vendor/MPVNativeEngine/lib/libmpv.2.dylib" && -f "$PWD/vendor/MPVNativeEngine/icd/MoltenVK_icd.json" ]] || { echo 'Incomplete MPV GPU runtime' >&2; exit 1; }
  ditto "$PWD/vendor/MPVNativeEngine" "$app/Contents/Resources/MPVNativeEngine"
fi
if [[ -d "$PWD/vendor/SubtitleTool" ]]; then
  for required in ffmpeg SOURCE.txt licenses/COPYING.LGPLv2.1 source/build.sh source/ffmpeg-n8.1.2.tar.gz; do
    [[ -f "$PWD/vendor/SubtitleTool/$required" ]] || { echo "Incomplete subtitle converter: $required" >&2; exit 1; }
  done
  ditto "$PWD/vendor/SubtitleTool" "$app/Contents/Resources/SubtitleTool"
  codesign --force --sign "$signing_identity" "$app/Contents/Resources/SubtitleTool/ffmpeg"
  codesign --verify --strict "$app/Contents/Resources/SubtitleTool/ffmpeg"
fi
cp config/Info.plist "$app/Contents/Info.plist"
if [[ -n "${MACTV_RELEASE_TAG:-}" ]]; then
  ruby tools/build/release-version.rb "$app/Contents/Info.plist" "$MACTV_RELEASE_TAG" "${MACTV_BUILD_NUMBER:?Release build number is required}"
fi
ruby -r./tools/build/native-runtime-materials.rb -e '
  app=ARGV.fetch(0); plist=File.join(app,"Contents/Info.plist")
  original,status=Open3.capture2e("/usr/libexec/PlistBuddy","-c","Print :LSMinimumSystemVersion",plist)
  abort "Cannot read application deployment target" unless status.success?
  minimum=NativeRuntimeMaterials.minimum_macos_for_bundle(app,baseline:original.strip)
  NativeRuntimeMaterials.require_macos_compatibility!(minimum,target:original.strip)
  _output,status=Open3.capture2e("/usr/libexec/PlistBuddy","-c","Set :LSMinimumSystemVersion #{minimum}",plist)
  abort "Cannot set bundled deployment requirement" unless status.success?
  puts JSON.generate(bundledMinimumMacOS:minimum)
' "$app"
source_revision="${MTV_SOURCE_REVISION:-unversioned}"
if [[ "$source_revision" == unversioned ]] && git rev-parse --verify HEAD >/dev/null 2>&1; then
  source_revision="$(git rev-parse --short HEAD)"
  if ! git diff --quiet HEAD; then source_revision="$source_revision-dirty"; fi
fi
[[ "$source_revision" =~ ^[a-zA-Z0-9._-]{1,80}$ ]] || { echo 'Invalid source revision' >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Add :MacTVSourceRevision string $source_revision" "$app/Contents/Info.plist"

for locale in en zh-Hans; do ditto "$PWD/resources/$locale.lproj" "$app/Contents/Resources/$locale.lproj"; done
iconset="$PWD/.build/MTV.iconset"
swift tools/build/generate-icon.swift "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$iconset/icon_512x512@2x.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  if [[ "$size" != 512 ]]; then
    sips -z "$double" "$double" "$iconset/icon_512x512@2x.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  fi
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/MTV.icns"
codesign --force --sign "$signing_identity" "$app/Contents/MacOS/MTVPluginHost"
codesign --force --sign "$signing_identity" "$app"
if [[ "$file_signing" == 1 ]]; then ruby tools/build/file-signing.rb sign "$app"; fi
codesign --verify --strict "$app"
target="$PWD/dist/MacTV.app"
if [[ -e "$target" ]]; then
  mkdir -p "$PWD/dist/previous"
  mv "$target" "$PWD/dist/previous/MacTV-$(date +%Y%m%d-%H%M%S)-$$.app"
fi
mv "$app" "$target"
rmdir "$stage"
printf 'Built: %s\n' "$target"
