# 第三方代码与资源

[English](THIRD-PARTY.md)

MacTV 的自有代码采用根目录 GPL-3.0 许可证。第三方文件保留原有版权和许可，不能用根许可证覆盖。

| 组件 | 来源 | 当前处理 |
| --- | --- | --- |
| libmpv 与依赖 | mpv-player/mpv；Homebrew 官方 bottles | Vendor 不纳入源码仓库；打包脚本记录版本、来源和许可证元数据 |
| MoltenVK | KhronosGroup/MoltenVK；Homebrew | 跟随原生 GPU 运行库准备，保留上游许可 |
| librime | rime/librime | BSD 许可；接口头和上游许可证保留在 src/Sources/RimeBridge/upstream |
| 拼音方案与词典 | rime 的 luna-pinyin、prelude、stroke、essay | 准备脚本保留 LICENSE / AUTHORS；数据各有原许可 |
| OpenCC | 同一 Rime 上游依赖包 | 保留许可及数据来源 |
| FFmpeg 字幕工具 | FFmpeg/FFmpeg | 最小 LGPL 构建；准备脚本附带对应源码、构建脚本与许可 |
| TypeScript | microsoft/TypeScript | 开发依赖，版本锁定在 tools/package-lock.json |
| 可选平台图标 | 官方网站与 App Store 图标来源 | 下载的图标留在本机，不纳入Git；无图标时应用卡片使用清单中的系统符号。来源见 resources/brand-icons/SOURCES.md |

公开源码不包含下载的运行库。公开二进制前，仍需逐项核对 libmpv 依赖的完整许可文本、对应源码、重链接要求和平台图标传播权利；现有 SOURCE.json 元数据不能代替这些材料。

默认包不携带 VLC。历史 VLC 与从 IINA 提取运行库的工具用于开发比较，不应被误当作已经完成公开分发核对的安装路径。

## 准备对应版本的分发材料

使用实际构建所用的 bottle 缓存，以及该运行库自己的 SOURCE.json：

```sh
ruby tools/build/package-native-mpv.rb --materials-from CACHE SOURCE.json OUTPUT
```

离线整理会逐项复制包根目录中的许可文件、固定版本配方及 SPDX 来源记录，不执行配方代码，不改变系统安装。添加 `--fetch-sources` 后，可下载并核对记录了上游 SHA256 的源码包和补丁。文件缺失、版本不一致或来源校验失败都不能算完成。Git 来源会读取配方固定的完整提交，验证 Git 对象并保存可独立使用的浅克隆仓库压缩包；自行生成的压缩包校验值与上游校验值分开记录。解压后可从其中的仓库克隆并构建，不会改用最新分支。

MATERIALS.json 分别记录材料是否齐全和许可审核是否完成。文件齐全不等于允许发布二进制；当前43个组件的对应源码与许可文件已收集齐全，打包和应用内署名仍需分别验收。

影视资料与海报来自各自服务；使用 TMDB 时需满足其 Logo 和应用署名要求。当前应用署名页仍在发布验收范围，不应省略后直接分发。平台 API、会员资格与素材版权由其服务规则约束。

`--pack-materials MATERIALS ARCHIVE` 只打包清单声明的源码、配方和许可文件；`--bundle-notices MATERIALS OUTPUT` 准备应用内的许可文本和组件索引，不把源码压缩包放进应用。两者都保留独立的审核状态。

构建会从实际捆绑的 Mach-O 部署命令计算最低 macOS 版本，不把编译 SDK 版本当成系统要求。依赖需要 macOS 26 时，安装包不会再声明只需要 macOS 15；源码目标兼容性单独说明。

默认构建不包含开发机下载的 B 站／夸克素材，使用清单中的原生图标；本机原文件保留。`MTV_INCLUDE_LOCAL_PROVIDER_ARTWORK=1` 仅用于明确选择的本地预览，不表示可再分发。TMDB 的正式署名图标独立打包。

即使已有顶层许可摘要，收集器也会读取已校验源码中的嵌套完整许可、SPDX 文本与含许可的 README，并区分来源与原始路径，保留旧编码字节。应用增加 IJG／FreeType 致谢和完整文本。当前 43 个原生组件收集到 343 份声明，替代之前只覆盖摘要的清单。

## Rime 构建依赖许可

`resources/rime/third-party/SOURCES.json` 记录现用 Rime 版本的依赖提交，以及其固定 macOS 构建流程中的 Boost 1.89.0。构建器检查并打包六个上游构建依赖的 23 份原始声明，同时保留上游测试和工具的许可；这不表示每个可选工具都链接进了应用。上游 release 目标将插件单独构建，MacTV 只使用核心 librime 动态库与所选数据，不携带单独的 Lua、predict、octagram 库。Rime 静态代码不属于 MPV 的 343 份声明覆盖范围。

许可文件保持上游原始字节。Markdown 声明额外添加 `.txt` 后缀，使仓库检查不把上游相对链接当成 MacTV 文档链接。来源索引保留固定提交、源码地址和归档校验信息，不为单个小许可文件计算哈希。Boost 完整源码归档尚未收集到本地，索引记录了上游地址与校验值。该清单不能替代完整二进制分发审核。

当前 MPV 运行时由对应的固定 0.41.0 源码重建，并回移上游 CoreAudio 修复 `3dae21b1ed4793912a8f9de1c5eb3cf32d227bce`；`MPVNativeEngine/source/mpv-local-build` 保留原源码、Homebrew 补丁、新修复、Vulkan 头文件与构建方法。元数据明确区分基础软件包和重建库，原 43 个依赖的清单与许可保留。[源码构建说明](../resources/native-mpv/README.zh-CN.md)不替代完整二进制分发审核。
