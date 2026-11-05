# 固定版本 MPV CoreAudio 源码构建

[English](README.md)

MPV 0.41 给 AudioUnit 声道映射接口传入了错误的数据结构。macOS 27 会返回 -50，并关闭声音，即使 HDMI 配置本身正确。本构建回移[上游修复 3dae21b](https://github.com/mpv-player/mpv/commit/3dae21b1ed4793912a8f9de1c5eb3cf32d227bce)，保留现有 43 个组件的依赖运行时，不强制立体声，不修改系统默认设备，不使用独占或空声音输出。多声道扬声器映射仍需单独验收；上游修复提到了原有问题 #15584。

先通过 `tools/build/package-native-mpv.rb` 准备原运行时对应的 Homebrew 缓存及源码材料。使用项目内 Python venv 安装固定版本 `meson==1.9.2`、`ninja==1.13.0`；解压 `TOOLS.json` 记录的 pkgconf 3.0.10 arm64 Sequoia 包，无需安装。下载 `BUILD.json` 固定的 Vulkan-Headers 源码归档。

在 ARM Mac 的 MacTV 源码目录运行：

```sh
ruby tools/build/rebuild-native-mpv.rb \
  --cache FROZEN_BOTTLE_CACHE --materials SOURCE_MATERIALS \
  --runtime ORIGINAL_RUNTIME --pkgconf EXTRACTED_PKGCONF_ROOT \
  --headers VULKAN_HEADERS_ARCHIVE --output .build/mpv-coreaudio-source-build
```

命令离线执行并检查源码身份。`MTV_MESON`、`MTV_NINJA` 可显式选择同版本工具。zlib、bzip2 元数据取自实际 Apple SDK 头文件；冻结依赖的 pkg-config 路径和链接别名只在构建目录中调整，不修改输入，不安装系统软件包。工作区锁阻止并发构建；准备完成后，编译或配置失败可使用相同输入续跑。

产物 `runtime/` 保留原依赖和许可，只替换 libmpv，移除构建机的绝对搜索路径；`source/mpv-local-build/` 携带 MPV 对应源码、原 Homebrew 补丁、上游修复、头文件和构建说明。OpenGL、Vulkan、原生硬件解码及声音驱动保持启用，不构建命令行播放器、手册和未使用的 VapourSynth 桥接。MacTV 本就关闭 mpv 脚本，并使用自己的插件宿主。

`SOURCE.json` 区分本地重建库与基础软件包；其中二进制校验值明确指应用签名前，应用签名会改变它。`RESULT.json` 只证明构建完成，不证明播放通过或允许公开分发。安装重建运行时后，需要执行 HDMI 和现代播放专项；电视实听、颜色和多声道映射分别验收。

## 系统兼容性

`BUILD.json` 将运行库目标设为 macOS 15.0，并选用 `arm64_sequoia` 包。
Homebrew 7 的命令行 API 会按本机系统过滤平台信息，因此改用官方完整配方 API，
按官方 SHA-256 校验归档，并按平台分别缓存；不会安装或升级系统软件。

MPV 的 Swift 编译步骤不继承 C 的系统版本参数，构建时需单独指定 ARM macOS 15 目标，
并检查 Swift 中间归档及最终库。应用打包会拒绝任何要求更高系统的二进制，
不会自动抬高应用最低版本。二进制检查不能代替 macOS 15 的实际运行验证。
