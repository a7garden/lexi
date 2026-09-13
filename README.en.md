# Lexi

[한국어](README.md) | **English** | [日本語](README.ja.md) | [中文](README.zh.md)

<p align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/AppIcon-128@2x.png" width="128" height="128" alt="Lexi app icon">
</p>

<p align="center">
  <strong>A local-first AI dictionary for macOS that instantly looks up unfamiliar expressions you select and builds them into your personal dictionary</strong>
</p>

<p align="center">
  <a href="https://github.com/project-oxi/lexi/releases/latest">Latest release</a> ·
  <a href="https://github.com/project-oxi/lexi/actions/workflows/ci.yml"><img src="https://github.com/project-oxi/lexi/actions/workflows/ci.yml/badge.svg" alt="CI"></a> ·
  <a href="https://github.com/project-oxi/lexi/releases"><img src="https://img.shields.io/github/v/release/project-oxi/lexi" alt="GitHub Release"></a>
</p>

Lexi instantly shows expressions you have already saved without an AI call, and creates explanations with a local MLX model only for expressions it is seeing for the first time. Web research runs only when you have turned it on, and only public material actually read is stored as a source.

## Key features

- Look up the currently selected text instantly with the `⌘D` global shortcut
- Support for **Ask Lexi** (Lexi에게 물어보기) in the macOS Services menu
- Clipboard lookup, dictionary opening, and Settings access from the menu bar
- A lightweight instant-look panel that appears near the cursor
- A personal dictionary that holds headwords, aliases, favorites, sources, and revision history
- Semantic search that uses multilingual embeddings to browse saved concepts by similar meaning
- Multilingual lookup that automatically detects and records eight languages, including Korean, English, Japanese, and Chinese. When you choose an explanation language, saved explanations written in that language are shown first
- An MLX-based local language model that runs on Apple Silicon
- DuckDuckGo-based web research, only when explicitly permitted by the user
- Revision history that stores AI drafts and user-edited versions separately

## Screenshots

| Full library | Instant lookup panel |
| --- | --- |
| ![Library window](docs/screenshots/library.png) | ![Instant lookup panel](docs/screenshots/instant-panel.png) |

![Settings window](docs/screenshots/settings.png)

## Installation

1. Download the latest `Lexi-*-macOS-arm64.zip` from [Releases](https://github.com/project-oxi/lexi/releases/latest).
2. Unzip it and move `Lexi.app` to the Applications folder.
3. Launch Lexi. Release artifacts are signed with a Developer ID and notarized by Apple.
4. The first time you use selected-text lookup, grant the **Accessibility** (손쉬운 사용) permission that macOS asks for.

> Lexi supports Apple Silicon Macs running macOS 14 Sonoma or later. The first AI generation downloads the selected MLX model from Hugging Face, so a network connection and several gigabytes of free disk space may be required.

## Usage

### Selected-text lookup

Select text in another app and press `⌘D`. Lexi reads the selection through the Accessibility API. Even if reading fails, it opens the dictionary window instead of falling back to the clipboard contents.

You can also choose **Services → Ask Lexi** from the app's right-click menu. This path receives the selected text without the Accessibility permission.

If the menu does not appear, press **Refresh list** (목록 새로고침) under Lexi **Settings → General → Right-click services** (설정 → 일반 → 우클릭 서비스), then reopen the menu of the app you were using. Also check that **Ask Lexi** is turned on under macOS **System Settings → Keyboard → Keyboard Shortcuts → Services** (시스템 설정 → 키보드 → 키보드 단축키 → 서비스). A service-providing app cannot pin its item to the top of another app's right-click menu; the menu layout is decided by the calling app. The fastest way to invoke Lexi is the global shortcut in Lexi settings, and to invoke it with a shortcut without the Accessibility permission, you can assign a dedicated shortcut to this item in the macOS Services settings.

### Dictionary and revision history

Use the search field and the category buttons in the left panel to browse the lists of all concepts, recent lookups, favorites, AI drafts, and manually written entries, and read the explanation on the right. Search covers concepts, aliases, and one-line definitions together. Pressing **Find by meaning** (의미로 찾기) groups saved concepts that do not overlap the regular search results and shows them ordered by multilingual embedding similarity. You can write entries yourself with **Add concept** (개념 추가) or `⌘N`, or look up a concept with AI by typing just its name. The list's right-click menu also supports favoriting and copying names.

If a saved headword or alias matches exactly, the result is displayed instantly. For expressions that are not in the dictionary, the local model creates a draft and saves it. What the AI produces is a draft, so review and edit important definitions yourself.

### Settings

- **MLX model**: Choose among Qwen3 4B (default) · 1.7B (lighter) · 8B (larger); the choice is saved immediately. With **Custom** (사용자 지정), you can enter an MLX model ID from Hugging Face directly and apply it.
- **Web research** (웹 조사): Off by default. When turned on, search queries and requests for public web pages are sent externally.
- **Shortcuts & permissions** (단축키·권한): Change the lookup shortcut and check the Accessibility permission in the General tab.
- **Explanation language** (설명 언어): Choose the language of the definitions and explanations the AI produces in the General tab. **Automatic** (자동) follows the language of the looked-up term and explains in Korean when detection fails. Each entry records the language of its term, aliases, and explanations, so even if the same concept has explanations in several languages, the explanation in the requested language is shown first.
- **Instant apply** (바로 적용): The model ID is saved when you press **Apply** (적용), and together with web research changes takes effect from the next lookup. There is no need to restart the app.

## Privacy and networking

- Dictionary data is stored locally at `~/Library/Application Support/Lexi/lexi.sqlite`.
- Looking up saved expressions uses neither the network nor AI.
- The generative model and the `multilingual-e5-small` weights used for semantic search are downloaded from Hugging Face the first time each feature is used.
- Semantic search runs only when you explicitly press **Find by meaning**, and the embeddings for the search query and the dictionary content are computed on the Mac. The embeddings are a derived in-memory cache and do not alter the dictionary's source text or revision history.
- DuckDuckGo searches and requests for search result pages happen only when web research is turned on.
- No telemetry or self-hosted analytics server is included.

## Building from source

Requirements:

- Apple Silicon Mac
- macOS 14 or later
- Xcode 16 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```bash
git clone https://github.com/project-oxi/lexi.git
cd lexi
brew install xcodegen
xcodegen generate
open Lexi.xcodeproj
```

In Xcode, select the `Lexi` scheme and run. This repository does not commit the generated `.xcodeproj`; `project.yml` is the source of truth for the project configuration.

Run the core package tests as follows:

```bash
swift test --package-path Packages/LexiCore
```

Verify an unsigned Release build:

```bash
xcodegen generate
xcodebuild \
  -project Lexi.xcodeproj \
  -scheme Lexi \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Project layout

```text
App/                         SwiftUI·AppKit app and instant-look UI
Packages/LexiCore/           SQLite, lookup, MLX, and web research core logic
docs/PDC-MIGRATION.md        Portable Document Contract import/export plan
AGENTS.md                    Repository work priorities and PDC application rules
project.yml                  XcodeGen project definition
.github/workflows/ci.yml     Test and unsigned build verification
.github/workflows/release.yml Developer ID signing, notarization, GitHub Release
```

## Key dependencies

| Package | Purpose | License |
| --- | --- | --- |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite storage | MIT |
| [mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples) | Local MLX LLM and multilingual embeddings | MIT |
| [mlx-swift](https://github.com/ml-explore/mlx-swift) | Embedding tensor operations | MIT |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | Global shortcuts | MIT |

Transitive dependencies include `swift-transformers`, `swift-collections`, `swift-numerics`, `swift-jinja`, and `GzipSwift`. Each is subject to the copyright and license of its own project.

## Release security

`v*` tags go through the following steps in GitHub Actions:

1. Import the Developer ID certificate into a temporary keychain
2. Create the Release archive and verify its code signature
3. Submit to the Apple notary service and wait for approval
4. Staple the notarization ticket and verify with Gatekeeper
5. Publish the GitHub Release together with a SHA-256 checksum

Certificates and passwords are stored only in GitHub Actions secrets and are never committed to the repository.

## License

No separate open source license has been granted for this repository at this time. The rights to copy, modify, and redistribute the code are not granted without separate notice.

Regression tests for the app's service declaration and invocation, and for settings:

```bash
xcodegen generate
xcodebuild -project Lexi.xcodeproj -scheme Lexi -configuration Debug \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
```
