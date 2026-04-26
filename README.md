# Apple Music Desktop Lyrics Overlay

一个可直接运行的 macOS 桌面歌词工具：把 Apple Music 的歌词和简体中文翻译显示在桌面悬浮层里。

[![Release](https://img.shields.io/github/v/release/yly02/apple-lyrics-overlay?display_name=tag)](https://github.com/yly02/apple-lyrics-overlay/releases/tag/v1.0.2)
[![License](https://img.shields.io/github/license/yly02/apple-lyrics-overlay)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-15%2B-111827)](https://github.com/yly02/apple-lyrics-overlay/releases/tag/v1.0.2)
[![Swift](https://img.shields.io/badge/Swift-6.1%2B-F97316)](Package.swift)

![Apple Music Lyrics Overlay showcase](docs/readme-showcase.png)

## 项目亮点

- 菜单栏常驻，跟随 Apple Music 当前播放状态
- 非中文歌词可显示原文 + 简体中文双排翻译
- LRCLIB + Apple Music 本地歌词 + lyrics.ovh 多路兜底
- 更稳的同步歌词候选匹配与自动纠错
- 更自然的歌词翻译润色，减少生硬直译
- 支持字体、字号、颜色、渐变、主题、动效和锁定位置

## 为什么做这个

- Apple Music 原生体验很好，但桌面悬浮歌词、双排翻译和细粒度自定义都不够直接
- 很多第三方歌词工具要么太重、要么不稳定、要么风格不够克制
- 这个项目想做的是一个更轻、更像原生 App、但又足够实用的 Apple Music 桌面歌词层

## 适合谁

- 常用 Apple Music，希望歌词能一直悬浮在桌面上的用户
- 听英文、日文、韩文歌曲时，希望同时看到简体中文翻译的用户
- 想要更轻量、更可自定义的桌面歌词工具，而不是完整播放器替代品的用户
- 喜欢自己调整字体、颜色、动效和位置的用户

## 截图

| 双排翻译 | 仅显示歌词 |
| --- | --- |
| ![Apple Music Lyrics Overlay screenshot 1](docs/overlay-shot-1.png) | ![Apple Music Lyrics Overlay screenshot 2](docs/overlay-shot-2.png) |

## 这是什么

- 菜单栏常驻的 Apple Music 桌面歌词应用
- 支持原文 + 简体中文翻译双排显示
- 支持歌词栏大小、字体、颜色、渐变、主题、动效、锁定位置
- 支持多种歌词兜底来源，提高无歌词歌曲的覆盖率
- 支持歌词自动纠错和更自然的翻译润色
- 翻译凭据只保存在本地，不进仓库

## 给普通用户：如何下载使用

### 方法 1：直接下载已打包版本

进入 GitHub 仓库的 [Releases](https://github.com/yly02/apple-lyrics-overlay/releases) 页面，下载：

```text
Apple-Music-Lyrics-<version>-macOS.zip
```

解压后把 `Apple Music Lyrics.app` 拖到 `Applications` 或任意你喜欢的位置，然后双击运行。

首次运行时，macOS 可能会要求你允许：

- Apple Events / 自动化控制 `Music`
- 辅助功能或相关桌面显示权限

允许后即可使用。

### 方法 2：从源码构建

要求：

- macOS 15.0 或更高
- Xcode / Swift 6.1 或更高工具链

运行开发版：

```bash
./run-overlay.sh
```

构建可双击启动的 `.app`：

```bash
./build-app.sh
```

默认会生成：

```text
~/Desktop/Apple Music Lyrics.app
```

## 功能概览

### 歌词显示

- 桌面悬浮歌词
- 跟随 Apple Music 当前播放进度
- 切歌时可显示歌名与歌手
- 中文歌词可只显示一行
- 英文、日文、韩文等非中文歌词可显示原文 + 简体中文翻译
- 更稳的同步歌词匹配与自动纠错，减少错句/错版本

### 自定义能力

- 歌词大小预设
- 自定义字体
- 自定义基础色和渐变色
- 跟随系统 / 始终浅色 / 始终深色
- 多种歌词切换动效
- 锁定 / 解锁歌词栏位置
- 记住上次窗口位置，支持多显示器

### 稳定性与兜底

- 预取当前句和下一句翻译，降低延迟
- 翻译请求超时自动降级，避免整条歌词卡住
- 翻译失败自动重试一次
- 本地持久化歌词缓存和翻译缓存
- 常见英文短句与语气词会做歌词化润色，减少生硬直译
- 多种歌词来源兜底：
  - LRCLIB
  - Apple Music 本地歌词字段
  - lyrics.ovh

### 更适合日常使用的细节

- 登录启动后可自动挂到菜单栏
- 记住歌词栏位置，支持多显示器回位
- 主题可跟随系统，也可强制浅色 / 深色
- 翻译、位置锁定、收藏当前歌曲等操作可直接从菜单栏完成

## 翻译说明

- 目标翻译统一输出为简体中文
- 翻译开关可在菜单栏中直接控制
- 翻译配置可在 `翻译设置…` 中修改
- 如果你配置了翻译 API，凭据会保存在本机：
  - macOS Keychain
  - 用户目录的 Application Support

这些内容不会被提交到 GitHub。

## 隐私与安全

- 仓库中不包含真实 API Key、Secret、密码或 token
- `.env`、构建产物、缓存、`.app`、`.build`、`dist` 都已被 Git 忽略
- README 截图只保留歌词栏本身，不包含其他桌面内容

## 项目结构

```text
Sources/apple-lyrics-overlay/apple_lyrics_overlay.swift   主程序
Resources/                                                菜单栏图标等资源
scripts/build-release.sh                                  打包发布脚本
build-app.sh                                              构建 .app
run-overlay.sh                                            开发运行
VERSION                                                   当前版本号
CHANGELOG.md                                              版本变更记录
```

## 给仓库维护者：如何发版

### 本地打包

```bash
./scripts/build-release.sh
```

会生成：

```text
dist/Apple Music Lyrics.app
dist/Apple-Music-Lyrics-<version>-macOS.zip
dist/Apple-Music-Lyrics-<version>-macOS.zip.sha256
```

### 手动上传到 GitHub Release

1. 先运行 `./scripts/build-release.sh`
2. 打开 GitHub 仓库的 `Releases`
3. 新建一个版本，例如 `v1.0.0`
4. 上传生成的 zip 和 sha256 文件

## 常见问题

### 1. 为什么有些歌没有歌词

并不是所有歌曲都能从外部歌词源拿到同步歌词。应用已经做了多路兜底，但仍可能遇到无歌词歌曲。

### 2. 为什么第一次运行会弹权限请求

因为应用需要读取 Apple Music 当前播放状态，并把歌词显示在桌面层，这些都需要 macOS 权限授权。

### 3. 为什么仓库里没有翻译 API 密钥

出于安全考虑，所有翻译凭据都只保存在本机，不会写入仓库。

## 已知限制

- Apple Music 没有公开的实时当前高亮歌词行接口，所以同步歌词仍然需要依赖外部歌词源和本地歌词字段做匹配与纠错
- 并不是所有歌曲都能拿到高质量同步歌词；有些歌只能退回纯文本歌词，或暂时无歌词
- 翻译已经做了歌词化润色，但本质仍是机翻增强，不保证每一句都达到人工填词级别
- 首次运行或系统权限变更后，可能需要重新允许自动化控制 `Music` 或相关桌面显示权限

## 版本

当前版本：`1.0.2`
最新发布：[`v1.0.2`](https://github.com/yly02/apple-lyrics-overlay/releases/tag/v1.0.2)
下载地址：[`Apple-Music-Lyrics-1.0.2-macOS.zip`](https://github.com/yly02/apple-lyrics-overlay/releases/download/v1.0.2/Apple-Music-Lyrics-1.0.2-macOS.zip)

详细更新见 [CHANGELOG.md](CHANGELOG.md)。

## License

MIT. See [LICENSE](LICENSE).
