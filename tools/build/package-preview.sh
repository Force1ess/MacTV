#!/bin/bash
# Package an already built app; never install it or publish a release.
set -euo pipefail
cd "$(dirname "$0")/../.."
app="${1:-$PWD/dist/MacTV.app}"
[[ -d "$app" && ! -L "$app" ]] || { echo 'Expected a real MacTV.app directory' >&2; exit 1; }
identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
[[ "$identifier" == local.mtv.preview && "$build" =~ ^[0-9]+$ ]] || { echo 'Unexpected app identity or build' >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$app"
mkdir -p dist/packages
revision="${MTV_PACKAGE_REVISION:-}"
[[ -z "$revision" || "$revision" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,31}$ ]] || { echo 'Invalid package revision' >&2; exit 1; }
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
ruby tools/build/release-version.rb "v$version" >/dev/null
volume="MacTV $version"
if [[ -n "${MACTV_RELEASE_TAG:-}" ]]; then
  release_version="$(ruby tools/build/release-version.rb "$MACTV_RELEASE_TAG" | sed -n 's/^version=//p')"
  recorded_version="$(/usr/libexec/PlistBuddy -c 'Print :MacTVReleaseVersion' "$app/Contents/Info.plist")"
  [[ "$release_version" == "$recorded_version" ]] || { echo 'Release tag does not match the built app' >&2; exit 1; }
  destination="$PWD/dist/packages/MacTV-${release_version}-arm64.dmg"
  volume="MacTV $release_version"
else
  destination="$PWD/dist/packages/MacTV-${version}-arm64${revision:+-$revision}.dmg"
fi
[[ ! -e "$destination" ]] || { echo 'Package already exists; inspect it before replacing' >&2; exit 1; }
stage="$(mktemp -d "$PWD/dist/package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
/usr/bin/ditto "$app" "$stage/MacTV.app"
ln -s /Applications "$stage/Applications"
cat > "$stage/Read Me.txt" <<'EOF'
MacTV

Quit MacTV, then drag MacTV.app into Applications.
Requires Apple Silicon and macOS 15 or later.
This build is signed for integrity checking but is not notarized by Apple.

Add your movie folder or SMB share in the setup guide. Choose your TV or speakers
as the audio output. Arrow keys move focus; Enter confirms; Esc/Backspace returns.

Chrome login import requires Full Disk Access for MacTV and permission to read
Chrome Safe Storage. Quit and reopen after granting access. QR login does not
need these permissions. MacTV sessions are stored locally in protected files.

Documentation: https://github.com/Force1ess/MacTV
Open-source notices are available in About MacTV. The release includes a separate
runtime source archive; rebuilt MPV and subtitle-tool source are inside the app.
EOF
cat > "$stage/安装说明.txt" <<'EOF'
MacTV

先退出 MacTV，再将 MacTV.app 拖入“应用程序”。
需要 Apple Silicon 与 macOS 15 或更新版本。
此构建已签名以校验完整性，未经 Apple 公证。

按首次引导添加影片目录或 SMB 共享，选择电视或扬声器作为声音输出。
方向键移动焦点，确定键打开，Esc／Backspace 返回上一级。

从 Chrome 导入登录前，需给 MacTV 开启完整磁盘访问权限，退出后重新打开。
首次导入可能请求读取 Chrome Safe Storage，信任此应用时可选择“始终允许”。
扫码登录不需要这些权限。MacTV 的登录信息只保存在本机权限受限文件中。

使用文档：https://github.com/Force1ess/MacTV
开源许可见“关于 MacTV”。发行版附有运行库源码包；重建 MPV 与字幕工具的源码在应用内提供。
EOF
/usr/bin/hdiutil create -volname "$volume" -srcfolder "$stage" -format UDZO "$destination"
/usr/bin/hdiutil verify "$destination"
echo "$destination"
