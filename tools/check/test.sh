#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
# Apple's standalone CLT places Swift Testing outside the SDK module search path.
frameworks="$developer/Library/Developer/Frameworks"
if [[ -d "$frameworks/Testing.framework" ]]; then
  # Recent standalone CLT packages Testing macros in a nested plugin directory.
  # -F resolves the framework, but does not teach swiftc where its macro lives.
  macros="$developer/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
  if [[ -f "$macros" ]]; then
    set -- -Xswiftc -load-plugin-library -Xswiftc "$macros" "$@"
  fi
  swift test -Xswiftc -F -Xswiftc "$frameworks" \
    -Xlinker -rpath -Xlinker "$frameworks" \
    -Xlinker -rpath -Xlinker "$developer/Library/Developer/usr/lib" "$@"
else
  swift test "$@"
fi
