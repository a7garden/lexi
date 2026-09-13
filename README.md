# Lexi

<p align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/AppIcon-128@2x.png" width="128" height="128" alt="Lexi 앱 아이콘">
</p>

<p align="center">
  <strong>선택한 낯선 표현을 바로 찾아보고, 내 사전으로 쌓는 macOS용 로컬 우선 AI 사전</strong>
</p>

<p align="center">
  <a href="https://github.com/a7garden/lexi/releases/latest">최신 릴리스</a> ·
  <a href="https://github.com/a7garden/lexi/actions/workflows/ci.yml"><img src="https://github.com/a7garden/lexi/actions/workflows/ci.yml/badge.svg" alt="CI"></a> ·
  <a href="https://github.com/a7garden/lexi/releases"><img src="https://img.shields.io/github/v/release/a7garden/lexi" alt="GitHub Release"></a>
</p>

Lexi는 이미 저장한 표현은 AI 호출 없이 즉시 보여주고, 처음 보는 표현만 로컬 MLX 모델로 설명을 만듭니다. 웹 조사는 사용자가 켠 경우에만 실행하며, 실제로 읽은 공개 자료만 출처로 저장합니다.

## 주요 기능

- `⌘D` 전역 단축키로 현재 선택한 텍스트를 즉시 조회
- macOS 서비스 메뉴의 **Lexi에서 찾아보기** 지원
- 메뉴 막대에서 클립보드 검색, 사전 열기, 설정 접근
- 커서 근처에 나타나는 가벼운 즉시 보기 패널
- 표제어·별칭·즐겨찾기·출처·수정 이력을 담는 개인 사전
- Apple Silicon에서 동작하는 MLX 기반 로컬 언어 모델
- 사용자가 명시적으로 허용한 경우에만 DuckDuckGo 기반 웹 조사
- AI 초안과 사용자 수정본을 구분해 저장하는 개정 이력

## 설치

1. [Releases](https://github.com/a7garden/lexi/releases/latest)에서 최신 `Lexi-*-macOS-arm64.zip`을 받습니다.
2. 압축을 풀고 `Lexi.app`을 응용 프로그램 폴더로 옮깁니다.
3. Lexi를 실행합니다. 배포 파일은 Developer ID로 서명되고 Apple 공증을 거칩니다.
4. 선택 텍스트 조회를 처음 사용할 때 macOS가 요청하는 **손쉬운 사용** 권한을 허용합니다.

> Lexi는 Apple Silicon Mac과 macOS 14 Sonoma 이상을 지원합니다. 첫 AI 생성 시 선택한 MLX 모델을 Hugging Face에서 내려받으므로 네트워크 연결과 수 GB의 여유 공간이 필요할 수 있습니다.

## 사용법

### 선택한 텍스트 조회

다른 앱에서 텍스트를 선택하고 `⌘D`를 누릅니다. Lexi는 손쉬운 사용 API로 선택 영역을 읽습니다. 읽기에 실패하더라도 클립보드 내용을 대신 사용하지 않고 사전 창을 엽니다.

앱의 우클릭 메뉴에서 **서비스 → Lexi에서 찾아보기**를 선택해도 됩니다.

### 사전과 수정 이력

저장된 표제어나 별칭이 정확히 일치하면 즉시 결과를 표시합니다. 없는 표현은 로컬 모델이 초안을 만들고 사전에 저장합니다. AI가 만든 내용은 초안이므로 중요한 정의는 직접 검토하고 수정해 주세요.

### 설정

- **MLX 모델**: 기본값은 `mlx-community/Qwen3-4B-4bit`입니다.
- **웹 조사**: 기본값은 꺼짐입니다. 켜면 검색어와 공개 웹페이지 요청이 외부로 전송됩니다.
- 설정 변경은 앱을 다시 시작한 뒤 적용됩니다.

## 개인정보와 네트워크

- 사전 데이터는 `~/Library/Application Support/Lexi/lexi.sqlite`에 로컬로 저장됩니다.
- 저장된 표현을 조회할 때는 네트워크나 AI를 사용하지 않습니다.
- 모델 가중치는 첫 사용 시 Hugging Face에서 내려받습니다.
- 웹 조사를 켠 경우에만 DuckDuckGo 검색과 검색 결과 페이지 요청이 발생합니다.
- 텔레메트리나 자체 분석 서버는 포함되어 있지 않습니다.

## 직접 빌드하기

요구 사항:

- Apple Silicon Mac
- macOS 14 이상
- Xcode 16 이상
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```bash
git clone https://github.com/a7garden/lexi.git
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
project.yml                  XcodeGen 프로젝트 정의
.github/workflows/ci.yml     테스트와 서명 없는 빌드 검증
.github/workflows/release.yml Developer ID 서명·공증·GitHub Release
```

## 주요 의존성

| 패키지 | 용도 | 라이선스 |
| --- | --- | --- |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite 저장소 | MIT |
| [mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples) | 로컬 MLX LLM | MIT |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | 전역 단축키 | MIT |

전이 의존성에는 `mlx-swift`, `swift-transformers`, `swift-collections`, `swift-numerics`, `swift-jinja`, `GzipSwift`가 포함됩니다. 각 저작권과 라이선스는 해당 프로젝트에 따릅니다.

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
