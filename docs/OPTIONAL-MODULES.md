# Optional modules

The first independent example packages are Gallery and Steam UI. Photo sources
are resource connections inside Gallery, not plugins. The current protocol and
remaining SDK migration limits are specified in
[Plugin architecture v2](PLUGGABLE-ARCHITECTURE.md)
([简体中文](PLUGGABLE-ARCHITECTURE.zh-CN.md)). Music is a legacy preview in this slice.

The first optional modules are small JavaScript adapters that share native
services. Their manifests declare access; module names and IDs do not grant
special privileges. These are development previews, not finished replacements
for the platform applications.

| Module | Implemented path | Acceptance boundary |
| --- | --- | --- |
| Gallery | Independent core with `host.library('photos')` adapter, folder browsing, thumbnail grid and remote-operated viewer | Selected local/media roots and connected cloud resources; no per-image-source plugin; generated previews use at most two concurrent reads |
| Music | `host.library('music')`, Apple's public iTunesLibrary API, search and local audio playback | Downloaded, unprotected songs; albums, playlists, local artwork and automatic next-track playback; subscription DRM remains unsupported |
| Steam | Fixed `applicationLaunch` manifest, application URL handoff and declared window matching | real Steam cold/warm open, fullscreen, scoped close and return verified through native window metadata; physical remote not tested |

## Plugin and host boundaries

Gallery is an independently buildable experience. Its adapter consumes the generic
`photos` resource port; the host supplies the shared grid, viewer, scoped image
reads and account isolation. Local directories, NAS shares and cloud accounts
are resource connections, not additional plugin packages. Legacy `pictures` and
`quark-pictures` capabilities remain only for existing v1 packages. Removing
Gallery does not remove those resources or the Quark account.

## Native library contract

Declare `library` in `capabilities` and the desired services in `nativeLibraries`.
`host.library(service, input)` returns the regular paginated media page. Input
uses string values for `page`, `reference` and `query`. Gallery translates the
ordinary module folder reference into the native service's `reference`.

`photo` and `audio` items have opaque references and cannot supply `url` or
`poster`. After validation the native host resolves them within that plugin's
authorized library. Scripts cannot inject arbitrary file URLs. Gallery folders
stay inside configured roots; escaping symlinks are rejected. NAS reads also
validate the current mount. Images use bounded reads and a 4096-pixel thumbnail
decode. This preview accepts image files up to 15 MB.

The Music service initializes only after a user opens a requesting module. A separate, cancelable reader has a 12-second parent deadline and a 20-second self deadline; a hung Apple library service cannot hold the other native libraries hostage.
macOS may ask for media-library permission. It uses the public framework, not a
parser for Music's private database. Tracks without a local file and protected
subscription tracks are excluded. No Apple account credentials are requested.

## Application launch contract

Declare `launch`, and supply an `applicationLaunch` with `bundleID`, a fixed
application URL, and `returnWhen: fullscreen-window-closes` or `matched-window-closes` with exact `windowTitles`. These declarations
are included in package review. Scripts cannot change the action at runtime.
The launcher does not execute shell commands or terminate the application.

The return tracker uses public window IDs, bounds and process ownership. Named-window rules use scoped Accessibility titles/geometry; no screen pixels or text-field values are read. It waits for two consecutive
samples without the observed fullscreen window and can return while the
application process remains alive. It avoids taking focus from unrelated
applications. A timeout reports that fullscreen was not observed; launching
the application alone is not counted as successful mode detection.

## 中文说明

相册、音乐和 Steam 都是实验性插件。相册目前读取已添加的本地媒体来源及有效
NAS 挂载，支持图片网格、原生看图和方向键切换；已连接夸克目录和原图。服务端没有缩略图时，对可见图片按需生成预览，最多并发读取两张，不批量下载整个网盘。
音乐通过 Apple 官方资料库接口读取本地、未受保护的歌曲并播放，首次使用可能
需要系统授权；支持专辑、播放列表和连续播放，已实测 21 首本地歌曲及曲尾自动续播。
Steam 使用声明的固定动作进入大屏模式，按插件声明的窗口标题与可见性判断返回，不要求
退出 Steam 进程；已从官方安装客户端，冷/热启动、全屏、窗口关闭后自动返回已通过原生窗口元数据验证；实体遥控仍未测试。
