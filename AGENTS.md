# AGENTS.md — Lexi

## 1순위 — Portable Document Contract v2 어댑터

- 사용자가 우선순위를 명시적으로 바꾸지 않는 한 `docs/PDC-MIGRATION.md`의 단계별 import/export adapter가 Lexi의 1순위 문서 상호운용성 작업이다. 다른 문서 교환 형식이나 동기화 설계를 시작하기 전에 가장 이른 미완료 safety gate를 진행한다.
- durable user-document import/export, 파싱, 렌더링, identity, 링크, 자산, 마이그레이션을 바꾸기 전에 설치된 `portable-document-contract` 스킬을 로드한다. PDC 외부 정본과 충돌하는 Lexi 전용 문법을 만들지 않는다.
- Lexi의 단일 진실은 내부 SQLite(`lexi.sqlite`, GRDB migration)다. PDC는 사용자 명시 import/export adapter이며, Lexi를 범용 vault editor로 만들거나 내부 DB를 파일 저장소로 교체하지 않는다.
- Export는 UUIDv7의 stable mapping을 유지하고 기존 파일 overwrite 전 digest를 검증한다. Import는 기존 revision을 덮어쓰지 않고 새 revision만 추가하며 `author`의 `ai`/`user` 구분, provider, aliases, language, favorite, sources, ordering을 보존한다. `lookupRecord`, 설정, 모델, 로그, 캐시는 문서가 아니다.
- 외부 계약은 `pdc-document/2`다. canonical ordinary 문서는 Obsidian 호환 lowercase `.md`(`pdc-markdown/1`: CommonMark+GFM 본문, safe YAML properties frontmatter)고, `pdc-query/1`은 별도 계약으로 쿼리 블록을 필요할 때만 데이터로 import·보존하며 절대 실행 권한을 갖지 않는다. Export는 Markdown만 만들고 자동·일괄 변환은 없다. `pdc-html/1`은 authored HTML이 중요할 때 first-class readable 입력이고, v1 Djot/HTML 문서는 보이는 읽기 전용 legacy로 안전하게 읽는다. unmarked/unsafe/unsupported 입력은 진단한다.
- Import/export는 preview와 명시적 사용자 확정 뒤 실행한다. Unknown data를 보존할 수 없으면 read-only/unsupported로 처리하며 조용히 누락하거나 자동 병합하지 않는다.

## Repository conventions

- 앱 UI와 문서는 한국어를 기본으로 하되 코드 식별자와 공개 API는 기존 Swift 스타일을 따른다.
- 핵심 패키지 검증은 `swift test --package-path Packages/LexiCore`로 수행한다.
- Schema 변경은 GRDB migration과 이전 schema에서의 up-test를 함께 추가한다.
