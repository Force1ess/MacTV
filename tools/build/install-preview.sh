#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ " $* " == *" --ui-smoke "* && " $* " != *" --supervised-ui-test "* ]]; then
  echo 'Use ruby tools/check/run-interactive-test.rb for installed-app UI tests.' >&2
  exit 1
fi

source_app="${MTV_PREVIEW_SOURCE:-$PWD/dist/MacTV.app}"
target_app="/Applications/MacTV.app"
# Legacy path is a migration input, not an installed display name.
legacy_app="/Applications/MTV.app"
expected_id="local.mtv.preview"
launch_current=false
if [[ "${1:-}" == "--launch-current" ]]; then launch_current=true; shift; fi
if [[ "$launch_current" == false ]]; then ruby tools/build/preview-artifacts.rb --configured --apply; fi
existing_app=""
for path in "$target_app" "$legacy_app"; do
  if [[ -e "$path" ]]; then
    [[ ! -L "$path" && -d "$path" ]] || { echo 'Unsafe installed app path' >&2; exit 1; }
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$path/Contents/Info.plist")"
    [[ "$identifier" == "$expected_id" ]] || { echo 'Refusing to replace another application' >&2; exit 1; }
    if [[ -z "$existing_app" ]]; then existing_app="$path"; fi
  fi
done
if [[ "$launch_current" == true ]]; then
  [[ "$existing_app" == "$target_app" ]] || { echo 'Install the renamed MacTV bundle before relaunching.' >&2; exit 1; }
else
  source_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")"
  [[ "$source_id" == "$expected_id" ]] || { echo 'Source identity mismatch' >&2; exit 1; }
  codesign --verify --deep --strict "$source_app"
  if [[ -n "$existing_app" ]]; then
    for artwork in bilibili.png bilibili.jpg quark.ico; do
      relative="Contents/Resources/BrandIcons/$artwork"
      if [[ "$artwork" == bilibili.jpg && -s "$source_app/Contents/Resources/BrandIcons/bilibili.png" ]]; then
        continue
      fi
      if [[ -s "$existing_app/$relative" && ! -s "$source_app/$relative" ]]; then
        echo "Update would remove $artwork. Restore the local artwork and build with MTV_INCLUDE_LOCAL_PROVIDER_ARTWORK=1." >&2
        exit 1
      fi
    done
  fi
  if [[ -n "$existing_app" ]]; then ruby tools/check/check-update-identity.rb "$existing_app" "$source_app"; fi
  # Prepare and verify the complete replacement before stopping the working app.
  stage="/Applications/.mactv-install-$$"
  mkdir "$stage"
  ditto "$source_app" "$stage/MacTV.app"
  codesign --verify --deep --strict "$stage/MacTV.app"
fi
process_pattern='^/Applications/(MacTV|MTV)\.app/Contents/MacOS/MTV( |$)'
# An explicit update owns relaunching. Stop test guardians first so they cannot
# reopen the old app while its installation is being replaced.
for guard_pid in $(pgrep -f "$process_pattern" || true); do
  guard_arguments="$(ps -p "$guard_pid" -o args= || true)"
  if [[ "$guard_arguments" == *" --test-runtime-guardian "* ]]; then kill -TERM "$guard_pid"; fi
done

for preview_pid in $(pgrep -f "$process_pattern" || true); do
  actual="$(ps -p "$preview_pid" -o comm= || true)"
  [[ "$actual" == "$target_app/Contents/MacOS/MTV" || "$actual" == "$legacy_app/Contents/MacOS/MTV" ]] || { echo 'Process identity changed' >&2; exit 1; }
  kill -TERM "$preview_pid"
done
for attempt in {1..50}; do
  if ! pgrep -f "$process_pattern" >/dev/null; then break; fi
  sleep 0.1
done
if pgrep -f "$process_pattern" >/dev/null; then
  echo 'Application did not exit; installation stopped without force-killing it.' >&2; exit 1
fi
if [[ "$launch_current" == false ]]; then
  mkdir -p backups
  for path in "$target_app" "$legacy_app"; do
    if [[ -d "$path" ]]; then
      archive="$PWD/backups/$(basename "$path" .app)-$(date +%Y%m%d-%H%M%S)-$$.app"
      mv "$path" "$archive"
      printf 'Previous installation retained: %s\n' "$archive"
    fi
  done
  mv "$stage/MacTV.app" "$target_app"
  rmdir "$stage"
fi
if [[ $# -gt 0 ]]; then open -n "$target_app" --args "$@"; else open -n "$target_app"; fi
