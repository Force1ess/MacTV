[English](TESTING.md)

# 开发与测试

构建使用 Xcode 26 / macOS 26 SDK 或更新版本。GitHub CI 在 macOS 15 runner 上显式选择 Xcode 26.3，日志记录 Xcode 与 SDK 版本；保留完整测试，不通过跳过应用编译来隐藏 SDK 不匹配。

CI 显式使用 `--no-parallel` 运行全部测试，避免小规格运行机上无关文件操作挤占带超时的本机通道测试；各项并发与取消测试自身的并发操作、生产超时和全部断言均保留。

## 自动检查

```sh
npm --prefix tools ci
npm --prefix tools run check:integrations
npm --prefix tools run test:integrations
bash tools/check/test.sh
ruby tools/check/check-source-release.rb
```

`tools/check/test.sh` 会处理独立 Command Line Tools 的 Testing 框架路径。可追加 `--filter MetadataTokenStoreTests` 选择专项。不要通过关闭断言或移除权限检查使测试通过。

## 开发构建留存

长期开发可用 `ruby tools/build/preview-artifacts.rb --configure --archive-root /Volumes/ArchiveDisk/.MacTV-Development/preview-archives --keep 3` 配置外置归档，卷名按实际替换。
配置只写入被 Git 忽略的 `.build`。随后构建与实际安装会分批归档较旧的生成应用，在每个目录保留近期回退副本；测试重启不创建新副本。
未配置时不会自动归档；`--disable` 只移除本机配置，不删除归档。

首次大量整理可显式追加 `--apply --limit 2000`。只处理已知生成名称、相同预览标识的旧应用，不处理正在运行的应用或任意备份目录。
副本检查通过且源未变化后才移除源；目标已存在、路径为链接或外置卷未挂载时拒绝移动。安装中的应用、代码、签名密钥、账号和影片不在范围内。
媒体盘中的隐藏开发目录会被正常扫描跳过；10项自建文件测试覆盖留存与异常保护。

## 应用内专项

自动化优先使用[本机控制接口](LOCAL-CONTROL.md)的结构化状态和事件。普通文字、选项、导航和流程状态不依赖截图。只有动画、布局或画面确有视觉验收需要时，才从远端导出图片到本机临时目录查看，不使用CUA。

准备完整运行依赖并构建后，启动专项会使用独立测试偏好域，并在应用自己的 TestResults 目录写入 PID、运行目录与检查结果。

```sh
ruby tools/check/run-interactive-test.rb --ui-smoke --modern-playback-only --windowed
ruby tools/check/run-interactive-test.rb --ui-smoke --system-text-input-only --windowed
ruby tools/check/run-interactive-test.rb --ui-smoke --source-management-only --windowed
ruby tools/check/run-interactive-test.rb --ui-smoke --chrome-login-only --windowed
ruby tools/check/run-interactive-test.rb --ui-smoke --owned-regression --developer-mode --tv-layout
```

同一时刻运行一个实例。现代播放专项包括真实自建媒体解码、音轨/字幕、播放菜单与 Escape/Backspace 返回映射；Chrome 专项使用自建 Cookie 数据，不代表真实账号导入完成。

`--owned-regression` 明确将初始资料库切到自建样本，不是 NAS 失败时的备用路径。普通启动与未带此开关的完整测试仍初始化所选实际来源。前台原生键盘专项需要应用处于可交互桌面；后台或锁屏失败不能算通过。

### 系统语音转写实测

`--system-text-input-only` 只验证原生输入，不证明听写成功。真实听写另用显式专项：

```sh
say -v Tingting -r 130 -o /tmp/mactv-owned-speech.aiff \
  '[[slnc 1000]]这是语音输入测试[[slnc 1000]]'
ruby tools/check/run-interactive-test.rb --windowed \
  --ui-smoke --system-dictation-only \
  --dictation-fixture /tmp/mactv-owned-speech.aiff \
  --dictation-virtual-input MiRemoteV2ch_UID --dictation-audio-start input-ready
```

只接受已选为默认输入的指定虚拟设备（MiRemoteV2ch_UID 或 BlackHole2ch_UID），音频最长10秒；不会退回物理麦克风或电视扬声器，不改变默认声音设备。测试通过真实原生输入点和应用自己的“听写”按键启动系统命令，把自建语音只送到指定虚拟输出，并等待系统实际转写、确认搜索。默认使用原生 Enter 事件，`--dictation-start-method direct` 只用于单独诊断命令分发。

`--dictation-audio-start input-ready` 最多等10秒，只有指定设备上出现新的输入客户端才播放自建语音，报告记录这段启动时间。默认 `immediate` 保留“命令分发后立即说话”的对照，不能把两种条件混为同一个时延统计，也不能用等待条件掩盖系统始终未启动采音的失败。

报告分开记录命令分发、原生输入事件、前台状态和指定设备的输入活动数量；CoreAudio 观察只读取进程/设备元数据，不采集音频、不输出进程身份或转写文本。全局安全输入状态只作相关性记录，不作为失败原因的自动结论。只有实际短语转写和最终提交均成功才通过。虚拟设备实测仍不等于物理遥控器麦克风验收。测试期间不要操作系统设置、切换窗口或运行其他前台专项。

原生输入框的确认和取消只会停止当前前台输入框自己的系统听写；旧控件销毁不会停止新输入框的听写。迟到的直接输入和候选文字都必须匹配当前会话。真实转写到达、确认后完整保留和固定短语准确率分别记录；不会把确认成功当作识别准确。

安装版结果可用 `ruby tools/check/verify-ui-run.rb PID 180` 观察。该工具只接受对应 PID 的最终报告，不能拿普通启动或旧报告当作本次测试结果。

`--player-timeline-only`覆盖当前支持的系统播放器与MPV，检查进度预览、确认/取消和后端实际时钟；普通包已不包含VLC，因此历史VLC专项不计入这项检查。汇总同时显示requestedScopeFullyVerified/nativePointerDragVerified等字段：检查通过而原生拖动未验证时，这两个状态分别保留，退出码规则不变。

### HDMI 声音输出

连接 HDMI 显示设备并准备好自建 AudioTimeline 样本后，运行低音量硬件专项：

```sh
ruby tools/check/run-interactive-test.rb --ui-smoke --windowed \
  --audio-output-only --test-audible-output
```

只有这一显式界面专项会取消 AVPlayer 和 MPV 静音，应用音量不超过 10%；其他界面测试仍静音。专项使用自建样本，不在 NAS 失败时改换样本，也不改系统默认设备或系统音量。MPV 的 `audio-device` 只表示请求配置，因此另外核对实际 CoreAudio 输出驱动、前进的声音时钟和格式，以及本应用进程正在使用的输出设备列表，不创建采集或音频 tap。HDMI 样本暴露了现用 MPV 0.41 的 CoreAudio 驱动在 macOS 27 上错误使用 AudioUnit 声道映射 API 的问题。显式立体声对照也失败，记录保留，无效的声道强制策略已移除。原生运行时需要上游修复 `3dae21b1ed4793912a8f9de1c5eb3cf32d227bce`。软件输出通过仍不等于电视扬声器实听或画质通过，报告保留这一差别。

## 真实视频卡片与标题布局

```sh
ruby tools/check/test-bilibili-focus-layout.rb 18
```

需要已运行的安装版、开启本机控制接口且没有正在播放的影片或弹层。专项读取真实B站首页，沿方向键路线跨行选择卡片，匹配当前PID/运行ID，等待标题边界连续稳定500毫秒，再检查展开后的完整标题是否落在可视区内。输出实际取样数量、展开标题数量与最大高度，不读取图片或Chrome登录；不会把网络分页失败改为自建内容。

取样范围为这一次首页的内容，不能代表所有视频标题。未发现超过两行的样本时，expandedTitleSamples会明确为0。500毫秒是验证布局稳定的条件，不计入首帧性能，也不修改播放基准的计时定义。

只有播放栏圆角和容器等布局需要视觉核对时，`test-quark-native-playback.rb --export-controls-layout`才在暂停时调用单独开启的visual.export；报告保留生成位置。图像只含MacTV内容视图，测试程序不读取图像。电影画面、声音与HDR输出的验收仍是另外的检查范围。

## 只读资料库接口

```sh
swift build --product MTVLibraryProbe
.build/debug/MTVLibraryProbe --inspect-selected --check --require-posters
.build/debug/MTVLibraryProbe --inspect /path/to/media --check
```

接口区分缓存索引与新扫描。结构错误、缺海报和操作失败分别返回非零；CLI 扫盘权限不证明图形应用权限。

`MTVMetadataProbe --audit-selected` 检查尚未匹配的内容；追加 `--use-saved-tmdb` 才会读取 MacTV 已保存的 TMDB Token。`--apply-automatic` 写入前必须退出 MacTV，先备份匹配文件，不修改影片和 NFO。

## 播放延迟

应用的播放基准记录解析、准备、可见帧和失败；目标配置在 config/playback-benchmarks.json。比较时固定账号模式、画质、样片、网络和缓存条件。失败样本必须保留，不能只统计成功请求。

按用户更新的标准，夸克首帧目标为 P99 ≤ 7 秒；哔哩哔哩 1080p 等较低分辨率仍为 ≤ 3 秒，其他来源的实际 4K 仍沿用 6 秒规则（解码长边至少3840、短边至少1600）。新夸克样本明确记录 `startupBudgetPolicy=quark-p99-7s-v1`。没有此标记的历史样本保留原 3 秒／6 秒解释，未知尺寸仍按旧规则为 3 秒；新标准复核采用派生结果，不改写原测量。少量样本只能作开发观察，不能据此宣布 P99 达标。真实 Bilibili 和夸克需分别测量，不能用本地样本代替。电视声音、HDR/杜比输出和物理遥控器需独立现场验收。

`--benchmark-session guest|stored` 显式选择账号模式。Bilibili 默认保留游客对照，已登录测速需指定 stored；夸克仅允许 stored。已登录模式没有本机有效配置时直接失败，不转成游客。每次记录 session 与实际 quality，两个模式不能混作同一组比较。

## 发布检查

`ruby tools/check/test-chrome-reader.rb /Applications/MacTV.app/Contents/MacOS/MTVChromeBridge` 验证组件协议、错误参数、拒绝不受信任的父进程和不输出密钥，共6项，不读取真实账号。Chrome界面专项另检查取消子进程、拒绝迟到启动，以及授权页的交互门槛和逐级返回。

真实授权保留测试必须分别记录：首次明确授权、重启后两个平台的无弹窗导入、主程序重新构建/安装后的同样导入。升级时读取签名中现成的组件内容身份进行对照；主程序可变化，登录组件需保持。授权失败不能改成读取已保存的平台会话来代替。

`ruby tools/check/check-source-release.rb` 检查拟纳入 Git 的源码和文档，包括链接、敏感内容与不应提交的文件。历史开发测量记录归档在 `docs/history`，供复现和对照早期结果。


真实账号播放验收可追加 `--qa-volatile-history` 启动参数，仅隔离观看记录，不改变播放后端、账号或网络策略；结束验收后正常重启应用，回到原有观看记录。报告中的 `volatileHistory` 明确记录本次是否隔离。


原片基准使用 `--playback-benchmark-only --live-services --benchmark-plugin mtv.quark --benchmark-session stored --benchmark-original-file --benchmark-reference FILE_ID`。
`--benchmark-runs` 设置试次数；libmpv 路径会验证原生截图尺寸与视频轨道一致，截图处理成本计入首帧上界，图片随即删除。
AVFoundation 与 libmpv 的观察方式分别记录，不能混作同一组统计。每条记录保留源码版本、进程冷热条件、失败、缓冲和三个阶段的耗时；不足 100 次不视为 P99 验收。

听写样本采用较慢语速，句子前后各留一秒静音。系统既可以通过原生插入，也可以先通过 marked text（待确认文本）交付转写；完成输入时必须提交真实文字。严格短句匹配仍然保留，不能用预期文本替换识别结果来通过测试。

### 已安装应用的界面测试

使用 `ruby tools/check/run-interactive-test.rb --ui-smoke TEST_SCOPE ...` 测试 `/Applications/MacTV.app`。安装器在停止日常应用之前，会拒绝未经监督的测试模式启动。存在播放、弹层或最近五分钟内的用户输入时，测试不会开始。原生守护程序在收到新用户输入或监督进程消失时结束测试，并在测试退出后重新打开日常模式。不要手动给用户正在使用的实例添加诊断参数来运行基准。

原片启动对照可以使用 `--benchmark-no-initial-buffer`，仅在受监督的界面基准中关闭 mpv 的初始缓存等待，不改变日常播放。`--benchmark-observe-seconds 30` 将首帧后的观察延长到 30 秒，可选范围为 3–300 秒；每个样本记录观察时间和初始缓冲模式。应与观察时间相同的默认缓冲配置分别比较。

哔哩哔哩基准先通过平台的正常查询接口取得完整视频卡片，再启动点击到首帧的计时，以保留合集、分 P 和续播检查。过去因构造卡片信息不完整产生的失败记录应保留在私有测试历史中，不计入成功播放样本。

### 独立示例插件与运行周期

`npm --prefix tools run test:plugins` 在独立插件工作区测试相册和 Steam UI；`npm --prefix tools run build:plugins` 生成可安装的 `dist/` 目录。两者都不依赖 MacTV 应用源码或 Xcode。

在空闲的开发应用中开启 `--enable-control --allow-plugin-management`，然后运行 `ruby tools/check/test-example-lifecycle.rb`。测试使用新的插件标识安装临时副本，执行相册、更新代码并检查输出，再禁用、启用和移除两个示例，核对应用 PID 未变且用户已有插件未被修改。测试会清理自己创建的样本与安装副本，不证明实体遥控器的 Steam 全屏返回。完成后恢复正常启动。

### Git 插件源界面

`ruby tools/check/test-plugin-sources.rb` 创建测试专用的本地 Git 仓库，并通过真实界面验证屏幕 URL 输入、clone/fetch、审核批准、新提交更新、禁用与移除来源、拒绝过期审核，以及已安装插件独立运行。测试核对用户已有插件和来源保持不变，并清理自己的数据。在空闲首页以 `--enable-control --allow-plugin-management` 启动测试，结束后恢复正常启动。该测试不能证明私有 GitHub 认证成功；私有源沿用用户已有的 Git/SSH 配置。

### 启动外部应用后的返回

`ruby tools/check/test-launcher-return.rb` 运行已安装的 Steam 插件，观察其声明的窗口，通过辅助功能确认实际全屏，关闭匹配到的窗口，并检查 MacTV 无需重启即可返回前台并获得键盘焦点。它不读取输入框内容，也不终止 Steam 进程；Steam 可能在最后一个窗口关闭后自行退出。实体遥控器按键需要另行验证。

原生顺序范围代理会逐步交付已经验证的响应字节。原片 Matroska 播放每个有序响应最多并行三个 10 MiB 读取，并非整个播放器只有 30 MiB 内存。仅供基准使用的 `--benchmark-range-bytes` 和 `--benchmark-range-depth` 用于控制变量对照，不改变正常播放。私有范围跟踪只记录偏移、字节数与耗时，不包含媒体 URL 或请求头。

夸克会员接口在此次观测中给出了 10 MiB 的优选范围大小。[OpenList 原片驱动](https://github.com/OpenListTeam/OpenList/blob/main/drivers/quark_uc/util.go)也使用 10 MiB 分块与三路并行读取。实际原片延迟和稳定性支持采用这个有上限的默认值；普通非流式读取仍保留 1 MiB 上限。会员状态返回码本身不证明会员已过期，也不保证实际带宽。

ARM 托管任务曾多次在分配运行器之前过期，因此源码 CI 使用 `macos-15-intel` 与 Xcode 26.3，只验证源码编译和测试样本。Apple Silicon 播放、真实账号与电视输出仍由 Mini 分别验收。

### 原生播放器事件

libmpv 桥接层持续消费公开客户端事件队列，并观察播放属性。频繁的界面状态更新读取缓存，避免同步查询播放器。帧编号是计算属性，mpv 不为它定期发送通知，因此在时钟变化时异步查询。明确的轨道或设置确认仍读取真实后端状态。

播放基准记录在现有元数据字段中包含 `nativeStartupTimeline` JSON，时间相对于点击起点。标准事件标记文件加载、输出重新配置和播放重启。显式开启 `--benchmark-log-stages` 才额外区分文件头、解封装与解码器日志阶段；其诊断开销单独记录，不与正常性能样本混合。只保留固定阶段标签和数字，不保留原始播放器日志、媒体 URL 或文件名。基准运行期间，`playback.diagnostics` 暴露同样的结构化时间线。源画面和真实解码尺寸仍须验证，每条记录注明观察方式，避免混合不兼容的历史测量。

`MTVQuarkProbe origin-layout FILE_ID --approved-quark-media-session` 读取有界的 EBML 元数据与跳转目标，不下载附件正文或输出片名。`origin-transfer` 比较使用系统代理与单次请求直连的读取，不修改全局代理或日常播放设置。基于 Data 回调的传输测量应与旧的逐字节诊断、完整点击到首帧延迟分别解读。

### 显式指定测速声音输出

Mini 日常使用 HDMI，测速时使用 `--benchmark-audio-output tv`；`system` 保留为默认及旧版本对照。HDMI 未连接、参数无效或重复指定时直接失败，不改选其他输出。该选项仅用于受监督的测速，不改变已保存的应用设置或系统设置，播放仍静音。每次记录请求路由、原生修复版本、实际声音驱动／格式／时钟及路由证据；HDMI 检查独立于首帧结果，原始样本、首帧计时和失败计数保持不变，预算采用明确记录的版本，不将不同输出路由的数据当作受控性能对照。

电视验收另加 `--benchmark-fullscreen`。首次点击前进入全屏；后续点击前等待浏览窗口恢复、获得前台／键盘焦点并填满显示器，单独记录这段恢复时间，不计入尚未发生的点击。启动期间，真实播放窗口必须在当前空间可见，且在请求全屏时填满显示器，才能接受解码帧；观察方式标签注明新增的可见性检查，同时记录显示方式、窗口尺寸和缩放比例。窗口模式和全屏数据不作受控对照。返回失败时保留已有样本与失败记录，不退回窗口播放，也不据此推断物理显示输出。

AVPlayer 的 HDMI 验证同时检查所请求的设备及本应用进程的真实 CoreAudio 输出活动。普通文件核对已启用的本地音轨，HLS 核对当前已选中且可播放的动态声音选项；HLS 的静态音轨计数为零不直接判作无声。媒体选择和原生输出活动必须同时成立。先前只检查静态轨道的失败保留；修正的是路由验证，不改变首帧计时。

AVPlayer 从原有首帧观察器已取得的同一张解码 CGImage 记录尺寸，不改变观察流程。早期 HLS 样本缺少尺寸时保留 3 秒未知尺寸预算，不事后改标为已验证的 1080p 样本。

AVPlayer 的“可显示”通知单独记为 `displayReady`；首帧事件 `renderReady` 只在当前可见窗口和解码 CGImage 均验证后记录，并包含取图成本，与原生路径一致。观察方式标签区分修正后的计时和历史通知时间，不修改历史样本。

夸克普通路径测速必须提供 `--benchmark-folder FOLDER_ID`，点击前通过有页数上限的正常目录接口取得真实文件卡片；找不到时直接失败，不构造文件名。MKV 卡片保留应用的原片策略。`--benchmark-original-file` 仍是显式原片传输实验，不伪装普通浏览。记录区分请求的原片模式与实际播放路径，保留扩展名（不保留文件名）及卡片来源。早期缺少真实文件名的转码探测不作为普通路径验收。

带请求头的 MP4／MOV 路径在 19 项自建检查、100 次 HDMI 全屏测量及独立 300 秒连续观察通过后，默认启用按播放隔离的连接复用。请求头、资源版本和取消仍各自隔离，共享会话不保存 Cookie 或凭据。`--test-isolated-header-session` 仅在显式界面测试中保留原传输对照；分段交付仍需显式开启，不是默认行为。
