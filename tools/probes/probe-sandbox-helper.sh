#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
probe_root="$PWD/.build/SandboxHelperProbe-$(uuidgen)"
probe_app="$probe_root/Probe.app"
mkdir -p "$probe_app/Contents/MacOS"
probe_developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
clang -isysroot "$probe_developer/SDKs/MacOSX.sdk" tools/probes/sandbox-helper-probe.c -o "$probe_root/control"
cp "$probe_root/control" "$probe_app/Contents/MacOS/Probe"
cat > "$probe_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.mtv.isolation-probe</string>
<key>CFBundleExecutable</key><string>Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
cat > "$probe_root/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.network.client</key><true/>
</dict></plist>
PLIST
printf 'GENERATED_CANARY_ONLY' > "$probe_root/read-canary.txt"
codesign --force --sign - --identifier local.mtv.isolation-probe --entitlements "$probe_root/entitlements.plist" "$probe_app"
codesign --verify --strict "$probe_app"
"$probe_developer/usr/bin/python3" -c 'import socket,pathlib,sys; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(); s.settimeout(30); pathlib.Path(sys.argv[1]).write_text(str(s.getsockname()[1])); [(lambda c:c.close())(s.accept()[0]) for _ in range(3)]; s.close()' "$probe_root/port.txt" &
probe_server=$!
trap 'kill "$probe_server" 2>/dev/null || true' EXIT
for probe_attempt in {1..50}; do [[ -s "$probe_root/port.txt" ]] && break; sleep 0.1; done
probe_port="$(cat "$probe_root/port.txt")"
"$probe_root/control" "$probe_root/read-canary.txt" "$probe_root/control-write.txt" "$probe_port" > "$probe_root/control.json"
set +e
"$probe_app/Contents/MacOS/Probe" "$probe_root/read-canary.txt" "$probe_root/sandbox-write.txt" "$probe_port" > "$probe_root/sandbox.json" 2> "$probe_root/sandbox.stderr"
probe_status=$?
set -e
printf '%s\n' "$probe_status" > "$probe_root/exit-status.txt"
cp "$probe_root/entitlements.plist" "$probe_root/no-network.plist"
/usr/libexec/PlistBuddy -c 'Delete :com.apple.security.network.client' "$probe_root/no-network.plist"
ditto "$probe_app" "$probe_root/NoNetwork.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.mtv.isolation-probe.nonetwork' "$probe_root/NoNetwork.app/Contents/Info.plist"
codesign --force --sign - --identifier local.mtv.isolation-probe.nonetwork --entitlements "$probe_root/no-network.plist" "$probe_root/NoNetwork.app"
set +e
"$probe_root/NoNetwork.app/Contents/MacOS/Probe" "$probe_root/read-canary.txt" "$probe_root/no-network-write.txt" "$probe_port" > "$probe_root/no-network.json" 2> "$probe_root/no-network.stderr"
no_network_status=$?
set -e
printf '%s\n' "$no_network_status" > "$probe_root/no-network-status.txt"
cat "$probe_root/control.json" "$probe_root/sandbox.json" "$probe_root/no-network.json" "$probe_root/sandbox.stderr" "$probe_root/no-network.stderr"
printf 'Probe artifacts: %s\n' "$probe_root"
