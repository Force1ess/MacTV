[English](LOCAL-CONTROL.md)

# 文本状态、事件和本机控制接口

开发与验收优先读取 MacTV 自己的状态、事件和操作结果，避免依赖截图、鼠标坐标或屏幕共享。接口操作同一个 AppModel / LoginController / 播放器，不是另一套模拟实现。

## 启用

```sh
bash tools/build/build-app.sh
bash tools/build/install-preview.sh --windowed --enable-control
```

普通启动默认关闭控制入口。已有同用户入口正在运行时拒绝覆盖；先退出旧实例再启动。关闭 MacTV 即停止监听，不安装后台服务，不使用 TCP/HTTP 端口。

安装版附带命令行程序：

```sh
/Applications/MacTV.app/Contents/MacOS/mtvctl status
/Applications/MacTV.app/Contents/MacOS/mtvctl modules
/Applications/MacTV.app/Contents/MacOS/mtvctl navigate settings
/Applications/MacTV.app/Contents/MacOS/mtvctl key backspace
```

源码构建的命令行程序为 `.build/release/mtvctl`。从外部使用时通过 SSH 登录该 Mac 的同一用户，再调用它；不需要向外开放控制端口。

下文的 `mtvctl` 是上述绝对路径的简写，可在当前开发 shell 中设置别名；SSH 非交互命令请直接使用完整路径。

`login.buttonDisplayTitles` 与 `login.displayMessage` 对应当前界面的本地化文字；旧 `buttons` / `message` 字段保留兼容，Chrome 资料名称不翻译。

## 状态与记录

`status` 返回当前实例的 PID、构建号、前台状态、导航与焦点、打开的面板、资料库刷新状态、模块加载情况、登录状态和播放进度。返回媒体条目时不输出解析后的视频地址或海报 URL。配置存在与本轮平台验证成功是不同字段；离线登录样例不能被标成真实平台验证。

开启后会在当前用户 `~/Library/Application Support/MTV/Control` 保存：

| 文件 | 内容 |
| --- | --- |
| state.json | 文本状态快照，带更新时间和 PID |
| events.jsonl | 当前运行实例最近512条结构化事件，含运行ID、PID、顺序号、时间、命令接受/拒绝与状态摘要 |
| control.sock | 本机 Unix socket |

目录权限为700，文件/socket为600，连接双方核对同一系统用户。不会输出 Cookie、Token、密码、二维码票据或带签名的播放地址；不记录请求参数原文，仅记录已校验的导航键、页面与设置标识。密码输入连长度也不输出。日志可能有影片标题和来源信息，不能未经处理提交到公开仓库。文件记录可能保留上一次运行；实时验证使用 `status` 并核对 PID 和 controlRunID，不以旧文件证明应用还在运行。新进程的事件序号从头开始。

```sh
mtvctl events
mtvctl events 20
```

事件每页最多64条，返回 nextAfter / hasMore / oldestAvailable，可明确发现环形记录已经覆盖旧事件。

## 命令

通用形式例如 `mtvctl call '{"command":"settings.open","arguments":{"id":"appearance"}}'`。参数值目前使用字符串。错误返回 ok=false 和稳定错误代码，进程退出1；成功读取或接受操作退出0。

| command | arguments | 行为 |
| --- | --- | --- |
| status | 无 | 当前实例状态 |
| window.show | 无 | 显示并请求激活 MacTV 自己的窗口，不解锁系统 |
| visual.viewport | width / height | 显式开启视觉导出时调整窗口内容尺寸；全屏时拒绝 |
| visual.export | purpose | 显式开启视觉导出时导出 MacTV 内容视图；仅 layout / animation / playback |
| events | after | 事件分页 |
| modules | 无 | 内容模块身份和标题 |
| navigate | section | home / library / bilibili / apps / settings |
| input.key | key | up/down/left/right/select/back/menu/home/escape/backspace |
| input.text | text | 只向已打开的非密码输入框输入文字 |
| input.open | 无 | 打开应用内非密码屏幕键盘，不自动开启麦克风 |
| input.diagnostics | 无 | 查看原生客户端、插入焦点、系统听写命令与启用状态；密码输入时拒绝，不开启麦克风 |
| settings.list | 无 | 设置分组、稳定ID和用户说明 |
| settings.open | id | 打开现有设置面板 |
| library.list | offset / limit | 当前资料库页面，最多100项 |
| library.refresh | full | 启动当前来源扫描；full为true/false |
| library.inventory | 无 | 从应用当前模型读取媒体整理摘要，不靠命令行另扫磁盘 |
| module.open | plugin | 打开指定模块 |
| module.list | offset / limit | 当前模块内容，最多100项 |
| module.next | 无 | 调用现有模块分页逻辑，不伪造页码 |
| item.activate | id | 按正常界面逻辑进入目录或播放 |
| item.describe | id | 读取当前条目的详细文字，不启动播放；列表预览的截断会明确标记 |
| account.open | plugin | 打开平台登录页 |
| account.importChrome | plugin | 主动触发本机 Chrome 导入，需额外启用 |
| account.chromeAccess | 无 | 只读观察当前 MacTV 进程中 Chrome 系统钥匙条目的锁定状态；不读取密钥、不修改授权 |
| account.selectProfile | plugin / name | 只选择当前列出的 Chrome 资料 |
| account.close | 无 | 关闭登录页 |
| account.revokeMediaSession | plugin | 撤销指定模块的原生播放会话范围，并停止该模块的当前播放 |
| playback.toggle | 无 | 暂停/继续 |
| playback.stop | 无 | 退出播放 |
| playback.rate | rate | 使用播放器实际支持的倍速 |
| playback.seek | seconds | 跳转到播放器的实际时间线位置 |

未知命令或额外参数拒绝执行。每条请求都有ID与过期时间，连接限制、帧大小和读取时间均有上限。操作返回 accepted=true 只说明启动了动作；例如资料库 refresh 还需等待 refreshing=false，登录要等平台验证状态，播放要等实际时间线，不能把 accepted 当完成。

library.list / module.list 要求相应页面已打开，避免读取到另一个页面的内容。扫描返回 result.job；状态中的 libraryScan 提供同一任务的 running / completed / limited / failed / timeout / cancelled 阶段、文件数、不可达数和错误域/代码。刷新验证必须匹配这个任务ID，不能仅以旧的文件数量不为零判断成功。

## 真实登录验收

需要控制入口之外再显式允许账号导入：

```sh
bash tools/build/install-preview.sh --launch-current --windowed --enable-control --allow-account-import
mtvctl import-chrome mtv.quark
mtvctl status
```

命令复用 MacTV 的本机资料发现、所选平台 Cookie 校验与平台验证流程，不在 SSH 中读取浏览器数据库。API默认非交互解密；普通界面导入也先无弹窗读取。只有显式选择“授权并导入”才允许请求系统确认。

此开关不授予 macOS 权限。login.chromeImportDiagnostic 提供 stage / domain / code / requiresSystemAuthorization，区分资料发现、Cookie读取、平台验证及完成；接口不返回会话内容。它限制为同一用户，但不保护已被恶意程序控制的同用户环境。

文件式钥匙串不可靠地遵守 LAContext 的禁用交互设置，Chromium 记录了同一问题（FB16959400）。读取改由独立组件通过公开旧式 API 控制自己的进程是否允许交互；不会改变登录钥匙串的锁定设置或其他应用策略。非交互子进程有10秒上限，交互式有5分钟上限，界面另保留20秒非交互后备期限。关闭/取消/超时会终止本次组件进程，使迟到结果失效；主程序退出也不会留下长期等待。

仅固定自签名证书不足以保证钥匙串授权跨更新复用。Apple 对不能归入正式开发者团队的程序使用其 CDHash 作为隔离身份。独立组件没有界面和 MTVCore 依赖，普通主程序修改不改变它的代码身份；安装检查分别报告主程序签名要求和登录组件内容身份。组件本身更新仍可能要求一次明确授权，不向现有 Chrome 钥匙添加宽泛的访问范围。

实现依据：[Apple 的进程身份计算](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/clientid.cpp)、[Chromium 的文件式钥匙串交互控制](https://chromium.googlesource.com/chromium/src/crypto/+/refs/heads/main/apple/scoped_keychain_user_interaction_allowed.cc)。这里的无弹窗实现不是跳过授权：没有权限会返回应用内授权页，读取不会偷偷成功。

导入开关同样约束通用导航指令：不能通过 input.key 选择“从Chrome导入”来绕过开关。默认不允许交互。仅在有人处理正常系统授权时，可同时追加 `--allow-account-interaction`；此标志还要求 `--allow-account-import`，状态中的 `accountInteractionEnabled` 明确记录。它允许本次原生导入等待系统确认，不会自动点击系统设置或授权窗口，也不替代 macOS 的授权。

`account.chromeAccess` 只请求条目引用和所属钥匙串的状态，不请求密码数据；`unlocked` 不代表 MacTV 已有读取该条目的权限，更不代表平台登录成功。不同安全会话的观察不能混作同一次 GUI 导入的证据。平台验证仍以当前运行中的 `platformVerifiedThisRun` 为准。

登录诊断中的 `reader=stable-native-helper-v1`、`interactive=false` 与 `platformVerified=true` 一起证明本次通过独立组件无弹窗导入并完成平台验证。只读钥匙元数据可显示允许列表条数和是否存在 MacTV 路径，但路径存在不等于隔离身份仍被接受。

`input.diagnostics` 的命令目标类别与原生输入事件计数用于定位听写链路，不包含输入文字。`microphoneStarted=false` 表示这条诊断本身不会启动麦克风；分发命令成功不能证明系统已经采音。

## 回归验证

```sh
bash tools/check/test.sh --filter LocalControlTests
ruby tools/check/test-app-control.rb /Applications/MacTV.app/Contents/MacOS/mtvctl EXPECTED_PID
ruby tools/check/test-app-control.rb --require-posters /Applications/MacTV.app/Contents/MacOS/mtvctl EXPECTED_PID
ruby tools/check/test-app-control.rb --expect-disabled /Applications/MacTV.app/Contents/MacOS/mtvctl EXPECTED_PID
```

应用专项需要开启入口、无正在播放的视频和已打开面板。它验证真实导航、两种返回键、设置、实际来源刷新、参数拒绝及事件记录，不生成截图，不修改原影片，不请求真实 Chrome 登录。API按键验证的是应用动作分发，不代表物理遥控器或macOS原生按键送达已通过。

每次回归都会匹配本轮扫描任务ID，再从应用当前模型检查整理结构与文件数，拒绝用旧缓存证明本轮成功；`--require-posters`额外要求当前来源0缺海报。可作为每次升级后的真实资料库检查，不写死385个文件，不注册定时任务，也不修改媒体文件。缺图仍会使严格检查失败，不通过隐藏影片让检查变绿。

`--expect-disabled` 需先正常启动且不带控制开关，检查应用实际运行、入口默认关闭、CLI不接受上次的状态文件。真实导入由 `ruby tools/probes/probe-control-import.rb mtv.quark` 单独显式测试，结果区分平台验证成功与未完成（退出2），不会输出凭据。

实际验证：本机通道5项、完整Core247项、运行中的应用严格检查26项、默认关闭3项通过。应用测试可能请求匿名登录二维码以检查菜单权限，但不会进入Chrome Cookie读取。

只有动画、布局或播放画面确实需要视觉检查时，才由 MacTV 自身在远端导出图片，拉到本机临时目录查看；不要用 CUA 或截图读取普通文字/状态。

视觉导出额外要求`--enable-visual-export`，控制接口本身不自动开启它。只输出MacTV自己的内容视图，不抓取系统桌面；登录、密码、屏幕键盘和SMB面板打开时拒绝。图片写入本机受限目录VisualExports，返回文件路径和像素尺寸，不在事件中记录图像内容。操作与滚动动画结束后再导出；刚接受的导航命令不证明新一帧已经绘制。验收结束后退出并不带该选项重开，关闭导出能力。

`input.dictationReadiness`区分输入未打开、原生文本客户端未准备、窗口不在前台以及系统开始命令是否可用；`lastDictationRequest`只表明分发结果，不能当作实际语音转写成功。`playback.cursorHideRequested`表示应用已向AppKit请求隐藏，不是读取到了屏幕上的光标可见性。

`mediaLayout`提供当前媒体网格选中标题的布局边界、可视区尺寸和是否完全落在可视区内，单位是应用内容坐标中的点。数据来自SwiftUI实际解析的标题边界，不根据文件名长度推算；没有当前焦点对应的布局时不返回旧条目。它不是系统屏幕的像素或遮挡检测。每帧布局变化不单独写事件，也不记录标题原文或媒体地址。

Chrome系统钥匙读取在同一进程内最多保留一个进行中的调用，覆盖两个平台和重试。界面超时后，若底层仍未返回，后续读取明确报告仍在等待，不再并发积累授权请求；不取消已有的系统授权，也不影响当前已保存的平台会话。


新增只读观察接口：`application.status`、`account.sessionStatus {plugin}`。状态中的 `nativeMedia` 报告相册/音乐面板、图片尺寸、音频进度和错误，不输出文件地址或账号凭据。

### Cloud photo preview checks

`gallery.preview {id}` decodes a cloud photo thumbnail through the same native loader used by the grid. The item must be a photo in the currently open Gallery page. The response contains only `decoded`, `width`, and `height`; it never exports pixels, signed URLs, or credentials. It may read the original image when the provider has no thumbnail. `gallery.status` reports read and decode counters.

For cloud images, counters preserve provider thumbnail failures separately from successful original-image reads. An optional thumbnail returning 401, 403, 404, or 410 is disabled for that gallery registration; the native loader then uses the already authorized original image, with the same two-read concurrency limit. Temporary server errors are not silently retried through the original-file path. No account cookies are sent to thumbnail CDNs.

### Managed example plugins

`plugins.list` returns installed IDs, versions and enabled states. Mutation is
disabled unless MacTV starts with `--enable-control --allow-plugin-management`.
`plugins.review {directory}` stages a package and returns its exact `manifest`
and `review` token. `plugins.approve {review}` installs that staged copy.
`plugins.enable {id, enabled:"true"|"false"}` and `plugins.remove {id}` share the
UI's managed store, quiescence and catalog reload. Invalid/missing review tokens
cannot install code. These commands never grant account import or general shell
execution. Restore an ordinary launch after developer verification.

### Git plugin source commands

`pluginSources.list` returns repository/ref/enabled metadata, never private keys.
Developer mutation flag `--allow-plugin-management` enables `pluginSources.add
{url}`, `pluginSources.enable {id,enabled}` and `pluginSources.remove {id}`.
`pluginSources.catalog {id}` fetches a Git snapshot and reports its revision;
`origin:"bundled"` explicitly selects the app-provided catalog instead.
`pluginSources.review {id,plugin}` stages that commit's package and returns a
review token for `plugins.approve`. Disabled/removed/changed sources cannot have
old pending reviews approved. Installed packages remain usable after removal.

`pluginManager` state exposes loading, source ID, catalog origin/revision,
entries, review identity and stable control IDs. `plugins.ui.activate {id}`
operates the real native manager. `input.submit` commits only an open nonsecret
on-screen input; it cannot submit passwords or account tokens.

`application.inspect` reads bounded window/button metadata only for the selected launcher application family; it skips text fields and passwords. `application.closeObservedWindow` requires the explicit developer mutation flag and closes only a window matching the selected launcher's reviewed declaration. It does not terminate the application.


`audio.status` 只读报告已选输出、系统默认、连接状态、已配置声道数及本应用进程的输出设备活动，不返回设备 UID，不启动播放或更改路由。`playback.diagnostics` 补充 MPV 实际声音驱动、格式、时钟、所选音轨、静音和音量；这些信息不证明扬声器实听。
