# Lexi

[한국어](README.md) | [English](README.en.md) | [日本語](README.ja.md) | **中文**

<p align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/AppIcon-128@2x.png" width="128" height="128" alt="Lexi 应用图标">
</p>

<p align="center">
  <strong>macOS 本地优先 AI 词典：即时查找选中的陌生表达，并沉淀为你的个人词典</strong>
</p>

<p align="center">
  <a href="https://github.com/project-oxi/lexi/releases/latest">最新发布</a> ·
  <a href="https://github.com/project-oxi/lexi/actions/workflows/ci.yml"><img src="https://github.com/project-oxi/lexi/actions/workflows/ci.yml/badge.svg" alt="CI"></a> ·
  <a href="https://github.com/project-oxi/lexi/releases"><img src="https://img.shields.io/github/v/release/project-oxi/lexi" alt="GitHub Release"></a>
</p>

Lexi 对已保存的表达无需调用 AI 即可立即显示，只为初次见到的表达用本地 MLX 模型生成解释。网络调查仅在你开启该功能时才会运行，并且只把实际阅读过的公开资料保存为来源。

## 主要功能

- 通过 `⌘D` 全局快捷键即时查询当前选中的文本
- 支持 macOS 服务菜单中的**询问 Lexi**（Lexi에게 물어보기）
- 从菜单栏即可进行剪贴板搜索、打开词典与进入设置
- 出现在光标附近的轻量即时查看面板
- 收录词条、别名、收藏、来源与修订历史的个人词典
- 基于多语言嵌入的语义搜索，将含义相近的已保存概念归在一起查找
- 自动判别并记录韩语、英语、日语、中文等 8 种语言的多语言查询。选择解释语言后，会优先显示以该语言写成的已保存解释
- 运行在 Apple Silicon 上的 MLX 本地语言模型
- 仅在你明确允许时才进行基于 DuckDuckGo 的网络调查
- 区分保存 AI 草稿与用户修改版本的修订历史

## 截图

| 完整词典 | 即时查询面板 |
| --- | --- |
| ![词典窗口](docs/screenshots/library.png) | ![即时查询面板](docs/screenshots/instant-panel.png) |

![设置窗口](docs/screenshots/settings.png)

## 安装

1. 从 [Releases](https://github.com/project-oxi/lexi/releases/latest) 下载最新的 `Lexi-*-macOS-arm64.zip`。
2. 解压后把 `Lexi.app` 移入“应用程序”文件夹。
3. 启动 Lexi。发行文件已使用 Developer ID 签名，并通过 Apple 公证。
4. 首次使用选中文本查询时，请允许 macOS 请求的**辅助功能**（손쉬운 사용）权限。

> Lexi 支持 Apple Silicon Mac 和 macOS 14 Sonoma 或更高版本。首次进行 AI 生成时会从 Hugging Face 下载所选的 MLX 模型，因此可能需要网络连接和数 GB 的可用空间。

## 用法

### 查询选中的文本

在其他应用中选中文本并按下 `⌘D`。Lexi 会通过辅助功能 API 读取所选区域。即使读取失败，也不会转而使用剪贴板内容，而是直接打开词典窗口。

也可以在应用右键菜单中选择**服务 → 询问 Lexi**。此路径无需辅助功能权限即可获取所选文本。

如果看不到该菜单，请在 Lexi **设置 → 通用 → 右键服务**（설정 → 일반 → 우클릭 서비스）中点击**刷新列表**（목록 새로고침），然后重新打开所用应用的菜单。同时请在 macOS **系统设置 → 键盘 → 键盘快捷键 → 服务**（시스템 설정 → 키보드 → 키보드 단축키 → 서비스）中确认**询问 Lexi** 已开启。提供服务的应用无法将条目固定在其他应用右键菜单的顶层，菜单的构成由调用方应用决定。最快的调用路径是 Lexi 设置中的全局快捷键；若希望在没有辅助功能权限的情况下使用快捷键调用，可在 macOS 服务设置中为该条目单独指定快捷键。

### 词典与修订历史

通过左侧面板的搜索框和分类按钮浏览全部概念、最近查询、收藏、AI 草稿与手动撰写列表，并在右侧阅读解释。搜索会同时匹配概念、别名与一句话定义。点击**按语义查找**（의미로 찾기）后，会以多语言嵌入相似度为序，成组显示与普通搜索结果不重叠的已保存概念。可以通过**添加概念**（개념 추가）或 `⌘N` 手动撰写，也可以只输入概念名称交由 AI 查询。列表的右键菜单还支持收藏与复制名称。

若保存的词条或别名完全一致，则立即显示结果。不存在的表达则由本地模型生成草稿并保存到词典。AI 生成的内容仅为草稿，重要定义请自行审阅并修改。

### 设置

- **MLX 模型**（MLX 모델）：在 Qwen3 4B（默认）、1.7B（轻量模型）、8B（大模型）之间选择，选定后立即保存。选择**自定义**（사용자 지정）后，可手动输入 Hugging Face 的 MLX 模型 ID 并应用。
- **网络调查**（웹 조사）：默认关闭。开启后，搜索词和公开网页请求会发送到外部。
- **快捷键与权限**：可在“通用”标签页中修改查询快捷键，并查看辅助功能权限。
- **解释语言**（설명 언어）：在“通用”标签页中选择 AI 生成的定义和解释所用的语言。选择**自动**（자동）时将跟随所查询术语的语言，判断失败时以韩语解释。每个条目都会记录术语、别名和解释的语言，因此即使同一概念存在不同语言的解释，也会优先显示所请求语言的解释。
- **即时生效**（바로 적용）：模型 ID 在点击**应用**（적용）后即被保存，并随网络调查的更改一起从下一次查询开始生效，无需重启应用。

## 隐私与网络

- 词典数据本地保存在 `~/Library/Application Support/Lexi/lexi.sqlite`。
- 查询已保存的表达时不使用网络或 AI。
- 生成模型和用于语义搜索的 `multilingual-e5-small` 模型权重会在各功能首次使用时从 Hugging Face 下载。
- 语义搜索只在你明确点击**按语义查找**时才会运行，搜索词和词典内容的嵌入计算全部在 Mac 本机完成。嵌入是派生的内存缓存，不会更改词典原文或修订历史。
- 只有在开启网络调查时，才会发生 DuckDuckGo 搜索和搜索结果页面请求。
- 不包含任何遥测或自有分析服务器。

## 从源码构建

要求：

- Apple Silicon Mac
- macOS 14 或更高版本
- Xcode 16 或更高版本
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```bash
git clone https://github.com/project-oxi/lexi.git
cd lexi
brew install xcodegen
xcodegen generate
open Lexi.xcodeproj
```

在 Xcode 中选择 `Lexi` scheme 并运行。本仓库不提交生成的 `.xcodeproj`，而是以 `project.yml` 作为项目配置的基准。

核心软件包测试的运行方式如下：

```bash
swift test --package-path Packages/LexiCore
```

验证未签名的 Release 构建：

```bash
xcodegen generate
xcodebuild \
  -project Lexi.xcodeproj \
  -scheme Lexi \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## 项目结构

```text
App/                         SwiftUI、AppKit 应用与即时查看 UI
Packages/LexiCore/           SQLite、查询、MLX、网络调查核心逻辑
docs/PDC-MIGRATION.md        Portable Document Contract 导入/导出计划
AGENTS.md                    仓库工作优先级与 PDC 应用规则
project.yml                  XcodeGen 项目定义
.github/workflows/ci.yml     测试与无签名构建验证
.github/workflows/release.yml Developer ID 签名、公证与 GitHub Release
```

## 主要依赖

| 软件包 | 用途 | 许可证 |
| --- | --- | --- |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite 存储层 | MIT |
| [mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples) | 本地 MLX LLM 与多语言嵌入 | MIT |
| [mlx-swift](https://github.com/ml-explore/mlx-swift) | 嵌入张量运算 | MIT |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | 全局快捷键 | MIT |

传递依赖包括 `swift-transformers`、`swift-collections`、`swift-numerics`、`swift-jinja` 和 `GzipSwift`。各自的版权与许可证遵循相应项目的规定。

## 发布安全

`v*` 标签会在 GitHub Actions 中经历以下流程：

1. 将 Developer ID 证书导入临时钥匙串
2. 创建 Release 归档并验证代码签名
3. 提交至 Apple notary service 并等待批准
4. 装订公证票据（staple）并通过 Gatekeeper 验证
5. 连同 SHA-256 校验和一起发布 GitHub Release

证书和密码仅保存在 GitHub Actions secrets 中，不会提交到仓库。

## 许可证

本仓库目前没有附带任何开源许可证。除非另行声明，否则不授予复制、修改或再分发代码的权利。

应用的服务声明、调用与设置回归测试：

```bash
xcodegen generate
xcodebuild -project Lexi.xcodeproj -scheme Lexi -configuration Debug \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
```
