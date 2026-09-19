# Changelog

이 프로젝트의 주요 변경 사항을 기록합니다.

## 1.2.2 - 2026-09-19

### Fixed

- 영어 UI에서 숫자가 1일 때 문법이 어긋나던 표기("1 items", "1 days", "1 aliases" 등). 숫자 치환 문자열 중 단일 숫자 키는 영어 복수형 variation(one/other)을 추가하고, 숫자가 두 개인 통계 문구는 복수형 variation으로 다룰 수 없어 영어만 라벨 형식("Aliases: 1 · Revisions: 2")으로 다시 번역했다. 한국어·일본어·중국어 표기는 수 변화가 없어 그대로다(앱: `Localizable.xcstrings`)
- 권한 없이 전역 단축키를 눌렀을 때 시스템 접근성 권한 프롬프트가 잠깐 떴다 사라지던 문제. 프롬프트(`AXIsProcessTrustedWithOptions`)는 비동기로 뜨는데, 직후 라이브러리 창을 열며 스스로 활성화하면(`NSApp.activate`) 시스템 프롬프트가 닫혀 버린다. 창 활성화를 먼저 끝내고 한 런루프 뒤에 프롬프트를 요청한다(앱: `AppDelegate.lookupFromSelection`)
- 시스템 설정에서 권한을 켠 뒤에도 설정 화면이 계속 "설정 필요"로 남던 문제. 상태는 앱이 활성화될 때만 다시 확인했는데, 허용 전에 이미 실행 중이던 프로세스는 반영이 늦거나 재실행 전까지 안 될 수 있다(`AXIsProcessTrusted`는 프로세스 단위). 설정 창이 열려 있는 동안 1.5초 간격으로 재확인하고, 여전히 "설정 필요"면 앱 재실행을 안내한다(앱: `SettingsView`)
- Safari 등 WebKit 웹영역의 선택 텍스트를 읽지 못하던 문제. 웹영역(AXWebArea)은 선택이 있어도 `kAXSelectedTextAttribute`를 noValue로 돌려주고, 선택을 WebKit 확장인 text marker range(`AXSelectedTextMarkerRange` + `AXStringForTextMarkerRange`)로만 노출한다. 표준 속성이 실패할 때 marker range로 폴백하고, 어떤 앱에서도 성공하지 못하던 2차 경로(앱 엘리먼트에 직접 질의 → 항상 attributeUnsupported)를 앱 포커스 엘리먼트를 거치도록 고친다(앱: `SelectedTextReader`)

## 1.2.1 - 2026-09-18

### Fixed

- iCloud 동기화를 켜면 첫 전송 처리 중 앱이 종료되던 문제. `CKSyncEngine` 위임 콜백(`handleEvent`) 안에서 엔진 메서드(`sendChanges`)를 기다리면 CloudKit이 콜백 직렬성 위반으로 fatal error를 일으키는데, 전송 실패 재시도(`zoneNotFound` 등)와 계정 로그인 직후 최초 업로드가 정확히 그 경로였다. 후속 전송을 detached Task로 넘겨 콜백 컨텍스트 밖에서 실행한다(앱: `CloudSyncService.continueOutsideDelegateCallback`)

### Changed

- 현지화 보강: 앱 전체 사용자 표시 문자열을 `String(localized:)`로 통일하고, 언어 배지·설정의 언어 표시명을 UI 언어를 따르는 `EntryLanguage.localizedName`으로 바꾼다(데이터 라벨은 기존대로 한국어 고정). 개발 언어(ko)를 프로젝트 설정에 명시하고 KeyboardShortcuts 의존성 핀을 확정하며 스크린샷·README를 갱신했다

## 1.2.0 - 2026-09-17

### Added

- 앱 UI 다국어 지원: 한국어(개발 언어)에 영어·일본어·중국어(간체) String Catalog를 추가하고 시스템 언어를 따른다. 서비스 메뉴 항목도 현지화하고, 언어 배지는 UI 언어에 맞춰 표시한다(LexiCore의 언어 메타데이터와 통계 데이터 라벨은 한국어 유지)
- MIT 라이선스: `LICENSE` 추가, 저장소 전체에 적용
- 통계 화면: 총 개념·총 조회·재조회률·평균 조회·연속 조회 일수 요약 카드, 가장 많이 조회한 단어 순위와 복습 후보("다시 볼 때가 된 단어"), 최근 30일 조회·저장 활동, 시간대별 조회, 언어·분야 분포, 저장되지 않은 검색어, 개념 임베딩 지도. 라이브러리 툴바의 통계 버튼이나 메뉴 막대 메뉴로 열고, 순위·지도의 점을 누르면 라이브러리에서 해당 개념을 연다. 지도 계산은 사용자가 명시히 요청할 때만 임베딩 모델을 내려받으며 벡터는 DB 정본에 쓰지 않는다(LexiCore: `LibraryStats`, `EmbeddingProjection`, `SemanticLibrarySearch.libraryEmbeddings`)
- iCloud 동기화: 설정 → 일반 → 동기화에서 켜면 CloudKit 개인 데이터베이스에 개념·별칭·개정본·출처를 동기화해 같은 Apple ID로 쓰는 기기에서 같은 사전을 쓸 수 있다. 로컬 SQLite가 정본이고 동기화는 파생 복사본이다. 오프라인 동안의 변경은 저널에 쌓였다가 이후에 밀어 올리고, 충돌은 개념 필드는 최근 수정 우선, 개정본·출처는 추가 전용, 삭제는 묘비로 수렴시킨다. 조회 통계·설정·모델은 동기화하지 않는다. 스키마 v3 마이그레이션이 따르며(모든 행에 동기화 UUID 부여), 실제 동기화에는 iCloud 컨테이너(`iCloud.kr.garden.lexi.app`) 등록과 서명이 필요하다(LexiCore: `SyncStore`, `SyncJournal`, `UUIDv7`; 앱: `CloudSyncService`)
- PDC Stage 0: `pdc-document-conformance/2` revision 2 corpus를 LexiCore 테스트 fixture로 연결하고 계약 판단을 테스트로 고정했다(LexiCore: `PDCContract`, `PDCConformanceCorpus`, `PDCConformanceTests`)

### Changed

- 라이브러리 사이드바: "내 사전" 헤더를 없애고 검색창을 최상단에 붙임
- 배포 형식: Release 아티팩트를 ZIP 대신 DMG(`Lexi-<버전>-macOS-arm64.dmg`, 열면 Applications 폴더로 드래그 앤 드롭해 설치)로 제공하고, DMG 파일 자체도 공증·스태플

### Fixed

- 출처 탭의 빈 상태가 스크롤 없는 콘텐츠로 바로 노출되면 상세 상단이 아래로 밀리던 여백 문제. 빈 상태도 다른 탭과 같은 스크롤 구조로 감싸 해결

## 1.1.0 - 2026-09-14

### Added

- 다국어 조회: 용어 언어 자동 감지(한국어·영어·일본어·중국어·프랑스어·독일어·스페인어·러시아어)와 항목·개정본·별칭의 언어 기록
- 설명 언어 설정(일반 탭): 자동(조회 언어 따르기) 또는 고정 언어. 요청 언어로 쓰인 저장 개정본을 우선 표시
- 패널·상세 화면의 언어 배지
- 오타 자동 보정: 정확 검색이 비었을 때 저장된 표현 중 철자가 가장 가까운 것(2편집 이내)으로 다시 찾고, 패널에 원본 → 보정 표기를 보여줌. 설정(일반 → 조회)에서 끄면 입력한 원본 텍스트를 그대로 사용하며, 조회 기록은 항상 원본 질의로 남는다
- 의미 검색: 일반 검색과 겹치지 않는 저장 개념을 다국어 임베딩 유사도순으로 표시. 임베딩 캐시는 메모리에만 유지하고 DB 정본은 바꾸지 않는다

### Changed

- 스키마 v2: `concept.lang`·`definitionRevision.lang` 컬럼 추가. 기존 데이터는 저장된 텍스트에서 언어를 되메우고, 판단 근거가 없으면 미상(NULL)으로 남는다

### Fixed

- 요청한 설명 언어의 개정본이 없을 때 언어 미상(NULL) 최신 개정본보다 다른 언어의 구개정본이 먼저 보이던 정렬 문제
- 별칭 언어 판정 실패 시 표제어 언어 대신 한국어로 고정 저장되던 문제
- 설정에서 아이콘 배치를 바꿔도 메뉴 막대 아이콘이 즉시 반영되지 않던 문제
- 라이브러리가 클 때 첫 조회가 패널을 멈추던 문제(DB 열기·마이그레이션을 MainActor 밖으로 이동)
- 웹 조사 저장이 성공한 뒤 조회 기록 쓰기가 실패하면 전체가 실패한 것처럼 보이던 문제
- 모델 ID의 앞뒤 공백만 정리해 적용할 때 '저장했어요' 확인이 바로 사라지던 문제
- 서비스 콜드 런치에서 첫 조회가 처리되지 않고 "어떤 개념이 궁금한가요?" 빈 패널만 뜨던 문제. 앱 기동 마무리가 서비스 처리 도중 만든 패널을 새로 만들어 조회 결과가 버려진 모델로 가는 경합이 원인. 패널 준비는 최초 1회만 수행하도록 바꿈
- 패널의 "내 사전 열기"·설정 버튼이 사전 창을 한 번도 연 적 없는 상태(서비스 콜드 런치 직후)에서 아무 동작 없던 문제. 창 클로저가 아직 없으면 Dock 재클릭과 같은 reopen 경로로 주 윈도우 씬을 만들고, 설정은 SwiftUI의 설정 액션으로 연다

## 1.0.0 - 2026-09-13

### Added

- 저장된 표제어와 별칭의 로컬 정확 검색
- Apple Silicon용 MLX 내장 생성 엔진
- 사용자 동의 기반 웹 조사와 출처 저장
- 커서 근처 즉시 보기 패널과 전체 사전 창
- 전역 단축키, macOS 서비스 메뉴, 메뉴 막대 앱
- AI 초안과 사용자 수정본의 개정 이력
- 앱 아이콘과 메뉴 막대 아이콘
- Developer ID 서명, Apple 공증, GitHub Release 자동화
