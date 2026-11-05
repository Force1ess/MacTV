[English](PLUGIN-DEVELOPMENT.md)

# 开发内容模块

以下保留 v1 开发接口；新插件可使用异步 API 2。即插即用与独立插件的新设计见
[Plugin architecture v2](PLUGGABLE-ARCHITECTURE.md)（[中文](PLUGGABLE-ARCHITECTURE.zh-CN.md)）；
独立示例包是 Steam UI；图片源是资源，不是插件。v1 保持兼容，0.3 示例已使用异步 API 2。

独立插件在 [MacTV-Plugins/main](https://github.com/Force1ess/MacTV-Plugins/tree/main) 开发，Steam UI 可独立构建和测试。
通用图片资源通过 `host.library('photos', input)` 访问；不要在插件中识别或安装图片源插件。

模块提供内容数据与播放描述，MacTV 负责原生界面、焦点和播放。无需为每个站点创建一套 SwiftUI 页面。

## 在独立仓库开发

```sh
git clone git@github.com:Force1ess/MacTV-Plugins.git
cd MacTV-Plugins/steam
npm ci
npm test
npm run build
```

基于 API 2 示例和 SDK，在自己的仓库创建插件，然后在 MacTV 添加对应 Git 来源安装。
无需主应用源码或 Swift 构建。开发宿主时，可用 `MACTV_PLUGINS_DIR` 指定自己的插件仓库；
默认构建通过 Git 获取官方仓库的 `main`，不使用子模块。

`src/plugin-api/mtv.d.ts` 和 `src/plugin-api/example.ts` 保留旧 API 1 的类型与示例。内置的哔哩哔哩、
夸克与音乐适配在 `src/integrations`，不是独立安装包；宿主测试样例在测试目录，不随应用打包。

## 最小返回值

```js
/** @type {MTVPlugin} */
const plugin = {
  handle(action, input) {
    if (action !== 'browse') throw Error('Unsupported action');
    return {items: []};
  }
};
```

`handle` 在受控宿主中同步执行。`browse` 返回 items 与可选 next；next 是平台游标，不是任意执行参数。视频条目使用稳定 reference，播放时通过 `resolve` 获取新地址，不把短期地址当作观看历史标识。

## 清单与能力

| 字段 | 含义 |
| --- | --- |
| id / version / apiVersion | 模块身份、模块版本与接口版本；当前 apiVersion 为 1 |
| entry | 固定为 plugin.js |
| domains | 允许请求的 HTTPS 域名 |
| capabilities | browse、search、resolve、login、folders、history、lookup、watchlist、continuation |
| playbackDomains | 视频地址的允许域名 |
| artworkDomains | 海报地址的允许域名 |
| authentication | 扫码、会话端点、Cookie 名称与成功状态声明 |
| postEndpoints | 允许 POST 的精确域名与路径 |
| requestUserAgent | 可选的固定请求头，最长512字节且禁止控制字符；随清单审阅，不允许脚本逐请求注入 |
| presentation | 图标、颜色、摘要、首页显示与开发开关 |

`mtv.` 是内置模块命名空间，`local` 为本地影片库保留。外部模块使用自己的唯一命名空间。

联网使用 `host.fetchJSON`，先核对 unknown 响应的状态与结构，再生成 MacTV 数据。不得把私有凭证放入 reference、URL、海报或错误信息。

非200响应只向脚本传递HTTP状态和可选的数字平台错误码，不传递原始错误正文、登录链接或凭证字段。固定User-Agent用于平台协议兼容，不改变账号授权和域名限制。

## 登录与播放

扫码的授权轮询、票据兑换和 Cookie 留在原生层。脚本通过 `host.sessionAvailable` 得知是否存在会话，并在获准的端点显式请求 authenticated。JavaScript 不接收原始会话字符串。

播放描述的 headers 只接受经过校验的 User-Agent 与固定 Referer，不接受 Cookie、Authorization 或 Host。所有媒体域名继续按清单核对。独立音频可以使用 audioURL；`indexed-fmp4` 当前仅兼容符合索引约束的清晰 AVC/AAC 分轨。

## 安装与测试

可在应用的模块管理中选择本地目录，审阅能力后安装、更新、停用或移除。尚无下载市场，不应安装不可信模块。

离线测试用已知响应检查状态映射、分页、权限与播放描述。真实登录、会员画质与平台风控需单独验证；离线通过不能替代平台实测。


原生相册、音乐资料库与应用启动契约见 [Optional modules](OPTIONAL-MODULES.md)。`nativeLibraries`、`applicationLaunch` 和 `localizedNames` 属于清单声明，安装审阅会展示相应能力。

## 异步 API 2

独立 SDK 位于 MacTV-Plugins/sdk，可单独 npm ci、npm test、npm pack，不依赖主程序或 Xcode。
清单声明 apiVersion:2；host.library 与 host.fetchJSON 返回 Promise，处理器可返回 Promise 或普通结果。
原生调用最多并行 4 个，每轮最多 64 次，退出/停用会取消整轮调用。返回前必须 await 所有原生工作。
不要把 v1 的同步调用直接当作 Promise 之外的第二条权限通道；域名、资源和账号规则仍由原生代理执行。
启动器可以声明 matched-window-closes、windowTitles 和 preferredPresentation；窗口业务规则归插件，宿主通用观察。
