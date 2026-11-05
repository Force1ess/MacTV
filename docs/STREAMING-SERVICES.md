# Netflix、Apple TV 与 DDYS 接入研究

当前尚未把这三个服务标记为已支持，也没有给现有应用添加伪装成播放器的空入口。

## 目标与两种集成

期望从 MacTV 的应用卡片进入内容，保持大屏操作与统一返回。受 DRM 保护的订阅服务不能复用 Bilibili / 夸克的普通媒体解析方式。

- 内嵌方案：MacTV 内承载官方网页的 WebKit 页面，让官方页面负责登录、授权和 DRM。是否播放成功需要真实账号验证，不能仅凭网页和 key-system 能力通过。
- 官方入口方案：卡片打开 Safari / 系统 TV App。可保留官方播放器，但会离开 MacTV，不算应用内播放完成。是否采用这一版由用户选择。

Netflix 官方在 Mac 推荐受支持浏览器，并明确列出 Safari 的 UHD/HDR 条件；Apple 提供系统 TV App。未发现这些说明承诺第三方 MacTV 可直接获得播放授权。也不能据此断言内嵌 WebKit 一定不可行。

## 正式能力探针

```sh
swift build -c release --product MTVStreamingProbe
.build/release/MTVStreamingProbe netflix
.build/release/MTVStreamingProbe apple-tv
```

src/Sources/MTVStreamingProbe 使用空的非持久网站资料，读取网页环境和测试配置的 key-system 能力，不读 Chrome/MTV会话、不取影片密钥、不请求内容许可证、不生成或读取图片。不在控制台记录网页内容、Cookie或令牌。仅允许预定官方主页面导航，35秒超时。

Mini 实测：

| 服务 | 主页面HTTP | HLS | 测试FairPlay配置 | 测试Widevine配置 | 实际影片 |
| --- | --- | --- | --- | --- | --- |
| Netflix | 200 | 可用 | accepted | not-supported-for-tested-configuration | 未登录验证 |
| Apple TV 网页 | 404 | 可用 | accepted | not-supported-for-tested-configuration | 未验证 |

这些结果只证明测试配置被WebKit接受。Apple TV返回404也不能视为其内容页面正常；不静默更换国家或账号地区来消掉失败。当前系统安装有 com.apple.TV 与 com.apple.Safari，可供官方入口方案使用，但应用存在不等于会员/地区/HDCP验证通过。

## 下一步验收

1. 确定用户接受官方外部播放器，还是要求始终留在MacTV。
2. 内嵌方案需独立网站存储、原生顶栏/返回、遥控焦点、可调用的文本状态与登录页边界；不能把网站当通用插件原生凭据接口。
3. 用用户有权访问的实际账号逐项验证登录、影片许可证、实际播放、声音、全屏、返回与画质。没有账号或许可证结果时保留未验证。
4. DDYS需要用户提供常用网址。存在大量同名页面，不根据搜索排名选站，不安装来历不明的描述文件或客户端，不假设第三方资源均可重分发。

来源：[Netflix在Mac使用说明](https://help.netflix.com/en/node/55764)、[支持浏览器与画质](https://help.netflix.com/en/node/30081)、[Apple TV Mac使用手册](https://support.apple.com/en-lamr/guide/tvapp-mac/apd78d48f1ce/mac)、[FairPlay Streaming](https://developer.apple.com/streaming/fps/)、[WKWebView](https://developer.apple.com/documentation/webkit/wkwebview)。
