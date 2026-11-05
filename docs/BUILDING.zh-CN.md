# 从源码构建 MacTV

[English](BUILDING.md)

## 环境

- Apple Silicon Mac，Xcode 26／macOS 26 SDK 或更新版本。
- Node.js 22、npm、Python 3 和 Git。
- 应用部署目标为 macOS 15.0；macOS 15 的实际运行验证仍待完成。

## 构建与运行

```sh
git clone https://github.com/Force1ess/MacTV.git
cd MacTV
npm --prefix tools ci
ruby tools/build/prepare-release-runtime.rb
make build
open dist/MacTV.app
```

运行库准备会下载并校验二进制及对应源码，再重编译 MPV，应用 macOS 声音修复。
可选插件在 MacTV 内从官方插件源安装。

`make package` 在 `dist/packages` 生成按版本命名的 DMG。自动发布流程见[发布指南](RELEASING.md)。

## 开发签名

经常在同一台 Mac 安装开发版本时，可以配置固定签名，减少系统重新请求权限：

```sh
bash tools/build/setup-rcodesign.sh
ruby tools/build/file-signing.rb setup
make build
```

签名私钥不纳入 Git。开发签名与 Developer ID 签名、公证分别配置。

进一步开发参阅[开发与测试](TESTING.zh-CN.md)、[项目结构](ARCHITECTURE.zh-CN.md)与[插件开发](PLUGIN-DEVELOPMENT.zh-CN.md)。
