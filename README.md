# Lexi

[한국어](README.md) | [English](README.en.md) | [日本語](README.ja.md) | [中文](README.zh.md)

<p align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/AppIcon-128@2x.png" width="128" height="128" alt="Lexi 앱 아이콘">
</p>

<p align="center">
  <strong>선택한 낯선 표현을 바로 찾아보고, 내 사전으로 쌓는 macOS용 로컬 우선 AI 사전</strong>
</p>

<p align="center">
  <a href="https://github.com/project-oxi/lexi/releases/latest">최신 릴리스</a> ·
  <a href="https://github.com/project-oxi/lexi/actions/workflows/ci.yml"><img src="https://github.com/project-oxi/lexi/actions/workflows/ci.yml/badge.svg" alt="CI"></a> ·
  <a href="https://github.com/project-oxi/lexi/releases"><img src="https://img.shields.io/github/v/release/project-oxi/lexi" alt="GitHub Release"></a>
</p>

Lexi는 이미 저장한 표현은 AI 호출 없이 즉시 보여주고, 처음 보는 표현만 로컬 MLX 모델로 설명을 만듭니다. 웹 조사는 사용자가 켠 경우에만 실행하며, 실제로 읽은 공개 자료만 출처로 저장합니다.

## 주요 기능

- `⌘D` 전역 단축키로 현재 선택한 텍스트를 즉시 조회
- macOS 서비스 메뉴의 **Lexi에게 물어보기** 지원
- 메뉴 막대에서 클립보드 검색, 사전 열기, 설정 접근
- 커서 근처에 나타나는 가벼운 즉시 보기 패널
- 표제어·별칭·즐겨찾기·출처·수정 이력을 담는 개인 사전
- 다국어 임베딩으로 저장된 개념을 뜻이 비슷한 항목끼리 찾아보는 의미 검색
- 한국어·영어·일본어·중국어 등 8개 언어를 자동으로 판별해 기록하는 다국어 조회. 설명 언어를 고르면 그 언어로 쓰인 저장 설명을 우선 보여줍니다
- Apple Silicon에서 동작하는 MLX 기반 로컬 언어 모델
- 사용자가 명시적으로 허용한 경우에만 DuckDuckGo 기반 웹 조사
- AI 초안과 사용자 수정본을 구분해 저장하는 개정 이력

## 스크린샷

| 전체 사전 | 즉시 보기 패널 |
| --- | --- |
| ![전체 사전 화면](docs/screenshots/library.png) | ![즉시 보기 패널](docs/screenshots/instant-panel.png) |

![설정 화면](docs/screenshots/settings.png)

## 설치

1. [Releases](https://github.com/project-oxi/lexi/releases/latest)에서 최신 `Lexi-*-macOS-arm64.zip`을 받습니다.
2. 압축을 풀고 `Lexi.app`을 응용 프로그램 폴더로 옮깁니다.
3. Lexi를 실행합니다. 배포 파일은 Developer ID로 서명되고 Apple 공증을 거칩니다.
4. 선택 텍스트 조회를 처음 사용할 때 macOS가 요청하는 **손쉬운 사용** 권한을 허용합니다.

> Lexi는 Apple Silicon Mac과 macOS 14 Sonoma 이상을 지원합니다. 첫 AI 생성 시 선택한 MLX 모델을 Hugging Face에서 내려받으므로 네트워크 연결과 수 GB의 여유 공간이 필요할 수 있습니다.

## 사용법

### 선택한 텍스트 조회

다른 앱에서 텍스트를 선택하고 `⌘D`를 누릅니다. Lexi는 손쉬운 사용 API로 선택 영역을 읽습니다. 읽기에 실패하더라도 클립보드 내용을 대신 사용하지 않고 사전 창을 엽니다.

앱의 우클릭 메뉴에서 **서비스 → Lexi에게 물어보기**를 선택해도 됩니다. 이 경로는 손쉬운 사용 권한 없이 선택한 텍스트를 받습니다.

메뉴가 보이지 않으면 Lexi **설정 → 일반 → 우클릭 서비스**에서 **목록 새로고침**을 누른 뒤 사용하던 앱의 메뉴를 다시 열어 보세요. macOS **시스템 설정 → 키보드 → 키보드 단축키 → 서비스**에서 **Lexi에게 물어보기**가 켜져 있는지도 확인하세요. 서비스 제공 앱은 다른 앱의 우클릭 메뉴 최상위에 항목을 고정할 수 없으며, 메뉴 구성은 호출 앱이 정합니다. 가장 빠른 호출 경로는 Lexi 설정의 전역 단축키이며, 손쉬운 사용 권한 없이 단축키로 호출하려면 macOS 서비스 설정에서 이 항목에 별도 단축키를 지정할 수 있습니다.

### 사전과 수정 이력

왼쪽 패널의 검색창과 분류 버튼으로 모든 개념·최근 조회·즐겨찾기·AI 초안·직접 작성 목록을 탐색하고, 오른쪽에서 설명을 읽습니다. 검색은 개념·별칭·한 줄 정의를 함께 찾습니다. **의미로 찾기**를 누르면 일반 검색 결과와 겹치지 않는 저장된 개념을 다국어 임베딩 유사도순으로 묶어 보여줍니다. **개념 추가** 또는 `⌘N`으로 직접 작성하거나 개념 이름만 입력해 AI로 조회할 수 있습니다. 목록의 우클릭 메뉴에서 즐겨찾기와 이름 복사도 지원합니다.

저장된 표제어나 별칭이 정확히 일치하면 즉시 결과를 표시합니다. 없는 표현은 로컬 모델이 초안을 만들고 사전에 저장합니다. AI가 만든 내용은 초안이므로 중요한 정의는 직접 검토하고 수정해 주세요.

### 설정

- **MLX 모델**: Qwen3 4B(기본)·1.7B(가벼운 모델)·8B(큰 모델) 중 선택하면 바로 저장됩니다. **사용자 지정**을 고르면 Hugging Face의 MLX 모델 ID를 직접 입력하고 적용할 수 있습니다.
- **웹 조사**: 기본값은 꺼짐입니다. 켜면 검색어와 공개 웹페이지 요청이 외부로 전송됩니다.
- **단축키·권한**: 일반 탭에서 조회 단축키를 바꾸고 손쉬운 사용 권한을 확인할 수 있습니다.
- **설명 언어**: 일반 탭에서 AI가 만드는 정의·설명의 언어를 고릅니다. **자동**은 조회한 용어의 언어를 따르고 판단에 실패하면 한국어로 설명합니다. 항목마다 용어·별칭·설명의 언어를 기록해, 같은 개념에 언어가 다른 설명이 있어도 요청한 언어의 설명을 우선 표시합니다.
- **바로 적용**: 모델 ID는 **적용**을 누르면 저장되며, 웹 조사 변경과 함께 다음 조회부터 적용됩니다. 앱을 다시 시작할 필요가 없습니다.

## 개인정보와 네트워크

- 사전 데이터는 `~/Library/Application Support/Lexi/lexi.sqlite`에 로컬로 저장됩니다.
- 저장된 표현을 조회할 때는 네트워크나 AI를 사용하지 않습니다.
- 생성 모델과 의미 검색용 `multilingual-e5-small` 모델 가중치는 각 기능의 첫 사용 시 Hugging Face에서 내려받습니다.
- 의미 검색은 명시적으로 **의미로 찾기**를 누를 때만 실행되며, 검색어와 사전 내용의 임베딩 계산은 Mac 안에서 이뤄집니다. 임베딩은 파생 메모리 캐시이며 사전 원문이나 개정 이력을 바꾸지 않습니다.
- 웹 조사를 켠 경우에만 DuckDuckGo 검색과 검색 결과 페이지 요청이 발생합니다.
- 텔레메트리나 자체 분석 서버는 포함되어 있지 않습니다.

## 직접 빌드하기

요구 사항:

- Apple Silicon Mac
- macOS 14 이상
- Xcode 16 이상
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```bash
git clone https://github.com/project-oxi/lexi.git
cd lexi
brew install xcodegen
xcodegen generate
open Lexi.xcodeproj
```

Xcode에서 `Lexi` 스킴을 선택하고 실행합니다. 이 저장소는 생성된 `.xcodeproj`를 커밋하지 않으며 `project.yml`을 프로젝트 설정의 기준으로 사용합니다.

핵심 패키지 테스트는 다음과 같이 실행합니다.

```bash
swift test --package-path Packages/LexiCore
```

서명되지 않은 Release 빌드 확인:

```bash
xcodegen generate
xcodebuild \
  -project Lexi.xcodeproj \
  -scheme Lexi \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## 구조

```text
App/                         SwiftUI·AppKit 앱과 즉시 보기 UI
Packages/LexiCore/           SQLite, 조회, MLX, 웹 조사 핵심 로직
docs/PDC-MIGRATION.md        Portable Document Contract 가져오기·내보내기 계획
AGENTS.md                    저장소 작업 우선순위와 PDC 적용 규칙
project.yml                  XcodeGen 프로젝트 정의
.github/workflows/ci.yml     테스트와 서명 없는 빌드 검증
.github/workflows/release.yml Developer ID 서명·공증·GitHub Release
```

## 주요 의존성

| 패키지 | 용도 | 라이선스 |
| --- | --- | --- |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite 저장소 | MIT |
| [mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples) | 로컬 MLX LLM·다국어 임베딩 | MIT |
| [mlx-swift](https://github.com/ml-explore/mlx-swift) | 임베딩 텐서 연산 | MIT |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | 전역 단축키 | MIT |

전이 의존성에는 `swift-transformers`, `swift-collections`, `swift-numerics`, `swift-jinja`, `GzipSwift`가 포함됩니다. 각 저작권과 라이선스는 해당 프로젝트에 따릅니다.

## 릴리스 보안

`v*` 태그는 GitHub Actions에서 다음 절차를 거칩니다.

1. 임시 키체인에 Developer ID 인증서 가져오기
2. Release 아카이브 생성과 코드 서명 검증
3. Apple notary service 제출과 승인 대기
4. 공증 티켓 스테이플 및 Gatekeeper 검증
5. SHA-256 체크섬과 함께 GitHub Release 게시

인증서와 비밀번호는 GitHub Actions secrets에만 저장하며 저장소에는 커밋하지 않습니다.

## 라이선스

현재 이 저장소에는 별도의 오픈 소스 라이선스가 부여되지 않았습니다. 별도 고지 없이 코드의 복제·수정·재배포 권한이 허용되는 것은 아닙니다.

앱의 서비스 선언·호출 및 설정 회귀 테스트:

```bash
xcodegen generate
xcodebuild -project Lexi.xcodeproj -scheme Lexi -configuration Debug \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
```
