# PDC v2 채택·마이그레이션 계획

상태: 최우선 상호운용성 어댑터 계획 · v2 계약 확정 · 구현 대기
외부 계약: `pdc-document/2`(문서), `pdc-query/1`(쿼리 블록, 별도 계약), 표준 commit `0ee51ea` · `pdc-document-conformance/2` revision 2
목표 역할: 명시적 PDC import/export adapter; Lexi 자체는 vault editor가 아님

v1(`pdc-document/1`, Djot 우선) 설계는 v2 Markdown 우선 설계로 대체되었다. v1 문서와 기존 사용자 파일은 계속 보이는 읽기 전용 legacy 입력으로 남는다.

Lexi의 내부 정본은 계속 `lexi.sqlite`다. PDC는 사용자가 사전 항목을 다른 앱에서 보거나 다른 앱의 문서를 사전 항목으로 가져오려고 명시적으로 선택할 때만 쓰는 어댑터 계약이다.

## 불변 조건

1. PDC 없이도 조회, 생성, 편집, 개정 이력, 출처 기능이 모두 동작한다.
2. export는 SQLite 정본을 바꾸지 않는 파생 파일 생성이다.
3. import는 기존 사용자 개정본을 덮어쓰거나 AI 초안으로 바꾸지 않는다. 새 내용은 새로운 `definitionRevision`으로만 추가된다.
4. `author`의 `ai`/`user` 구분, provider, 출처, 별칭, 언어, 즐겨찾기, 개정 순서를 보존한다.
5. `lookupRecord` 같은 행동 기록은 사용자 문서 내용이 아니므로 export하지 않는다.
6. import/export는 사용자 명시 동작이며 백그라운드 자동 동기화가 아니다.
7. 자동 변환과 일괄 변환은 없다. legacy 문서는 읽기만 하며 파일을 다시 쓰거나 다른 형식으로 바꾸지 않는다.

## v2 표현 계약

### 프로파일과 우선순위

- 문서 계약은 `pdc-document/2`다. envelope·identity 판별은 외부 `pdc-document/2` 정본을 따른다.
- canonical ordinary 문서 프로파일은 `pdc-markdown/1`이다: lowercase `.md` 파일, CommonMark+GFM 본문, Obsidian 호환 safe YAML properties frontmatter.
- `pdc-query/1`은 문서 계약과 분리된 별도 버전 계약이다. 쿼리 블록은 필요할 때만 import해 데이터로 보존하며, 절대 실행 권한(executable authority)을 갖지 않는다. 지원하지 않는 쿼리 계약 버전은 opaque 보존하거나 unsupported로 진단한다.
- `pdc-html/1`은 authored HTML이 중요한 문서를 위해 first-class readable 입력으로 유지한다.
- v1 `pdc-djot/1` `.djot` 문서와 v1 marked HTML은 계속 보이는 읽기 전용 legacy다. 안전하게 읽고 preview할 수 있지만 export 대상이 아니다.
- unmarked/unsafe/unsupported 입력은 자동으로 가져오지 않고 진단한다.

### Export (`pdc-markdown/1`)

- 사전 concept 하나를 lowercase `.md` 문서 하나로 내보낸다. export는 Markdown만 만든다.
- frontmatter는 YAML 1.2 Core 기반의 Obsidian 호환 safe properties로 쓴다: `title`(preferred term), `lang`(항목 언어), `aliases`(표준 필드), `favorite`(즐겨찾기). Writer는 Obsidian Properties가 직접 다루는 text·list·number·checkbox·date·date-time을 우선 사용하고, Reader는 JSON-compatible nested map/list까지 안전하게 읽어 보존한다. anchor·alias·명시적/custom tag·복수 문서·실행 가능한 구문은 금지한다.
- 본문은 CommonMark+GFM으로 최신 사용자 정의와 읽기 쉬운 개정 이력·출처를 기록한다.
- 전체 revision/provenance 구조는 `lexi_revision_history_json` 사용자 property에 opaque JSON 문자열로 보존하며 다른 앱은 그대로 왕복한다.
- 기존 파일 overwrite 전에는 source digest와 expected target state를 검증한다(digest guard).

### Stable identity

- SQLite autoincrement ID는 PDC 문서 ID가 아니다.
- 첫 export 때 UUIDv7을 할당하고 `pdc_document_map(concept_id, pdc_document_id)`에 영구 저장한다. 추가는 정상적인 GRDB migration(다음 스키마 버전)과 이전 schema up-test를 동반한다.
- 같은 concept의 반복 export는 동일 PDC UUID를 쓴다.
- legacy concept ID는 필요할 때 `lexi_legacy_id` 사용자 property로 보존한다.

### Import

- `pdc-markdown/1` lowercase `.md`를 정식 입력으로 읽는다. `pdc-html/1`은 authored HTML이 중요할 때 같은 등급으로 읽는다. v1 `pdc-djot/1`과 v1 marked HTML은 보이는 읽기 전용 legacy로 같은 안전 규칙으로 읽는다.
- unmarked Markdown, unsafe frontmatter, unsupported profile, malformed envelope는 자동으로 가져오지 않고 진단한다.
- `pdc-query/1` 블록은 필요할 때만 import하며 데이터로만 보존한다. 실행하지 않는다.
- PDC UUID 매핑이 있으면 해당 concept를 대상으로 한다. 없으면 정확한 alias/text+language 일치를 제안하되 자동 병합하지 않는다.
- 동일 revision payload digest가 이미 존재하면 멱등하게 건너뛴다.
- 충돌·모호성·필드 손실을 preview한 뒤 사용자가 확정하면 하나의 DB transaction으로 기록한다.

## 단계

### Stage 0 — fixture와 계약 고정

- `pdc-document-conformance/2` revision 2를 LexiCore 테스트 fixture로 연결한다.
- `pdc-document/2` envelope·frontmatter schema, `pdc-markdown/1` 본문 layout, `pdc-query/1` 참조 방식, `lexi_*` 사용자 property, revision digest, UUID mapping migration을 문서와 테스트로 고정한다.

완료 조건: 동일 입력이 항상 동일 export 계획과 import preview를 만든다.

### Stage 1 — 순수 codec

- LexiCore에 파일 I/O가 없는 codec을 추가한다: safe YAML properties writer와 strict reader, `pdc-markdown/1` Markdown writer/reader, `pdc-query/1` 블록 encode/decode, legacy reader(`pdc-djot/1`, `pdc-html/1`, v1 marked HTML).
- 모든 profile에서 안전한 표시 텍스트 projection을 추출한다. unsafe/unsupported 입력은 진단으로 분류한다.
- unknown fields/extensions는 보존하거나 import 계획에서 명시적으로 unsupported 처리한다.

완료 조건: corpus 분류와 encode/decode round trip이 Swift 테스트에서 통과한다.

### Stage 2 — stable UUID와 Markdown export

- `pdc_document_map` GRDB migration과 이전 schema up-test를 추가한다.
- 사용자가 선택한 concept를 새 lowercase `.md` target으로 export한다.
- 기존 파일 overwrite 전에는 source digest와 expected target state를 검증한다.

완료 조건: 반복 export가 같은 UUID를 사용하며 SQLite 내용은 변하지 않는다.

### Stage 3 — preview-first import

- import plan UI에 대상 concept, 생성될 revision, aliases, sources, conflicts, 쿼리 블록 처리(보존/unsupported)를 표시한다.
- 사용자 확정 뒤 하나의 DB transaction으로 새 revision과 매핑을 기록한다.
- 같은 파일 재-import는 중복 revision을 만들지 않는다.

완료 조건: AI/사용자 author 구분과 기존 revision이 모든 fixture에서 보존된다.

### Stage 4 — 교차 앱 검증

- Oximemo와 Sawhorse가 Lexi Markdown export를 동일 ID·제목·별칭·본문으로 읽는지 검증한다.
- Lexi가 대표 Obsidian 호환 Markdown, `pdc-html/1`, v1 legacy 문서를 안전하게 preview하고 선택적으로 가져오는지 검증한다.

완료 조건: `pdc-document-conformance/2` revision 2와 공통 representative-vault suite가 모두 통과한다.

## 비목표

- SQLite를 파일 기반 PDC 저장소로 교체하지 않는다.
- Lexi를 범용 vault 브라우저나 문서 편집기로 만들지 않는다.
- 자동 양방향 동기화, background export, path 기반 identity를 만들지 않는다.
- export는 Markdown만 만든다. Djot·HTML export는 없다.
- 자동 변환·일괄 변환은 어떤 방향이든 없다. legacy→Markdown, HTML→Djot 변환도 없다.
- 쿼리 블록에 실행 권한을 주지 않는다. 쿼리는 데이터다.
- 행동 기록, 모델 파일, 설정, 캐시를 PDC로 내보내지 않는다.

## 검증

```bash
swift test --package-path Packages/LexiCore
xcodegen generate
xcodebuild -project Lexi.xcodeproj -scheme Lexi -configuration Release CODE_SIGNING_ALLOWED=NO build
```

PDC v2 구현 시 `pdc-document-conformance/2` revision 2, `pdc_document_map` schema up-test, repeated-export identity, repeated-import idempotence, author/provenance preservation, safe-YAML/unsafe-input diagnostics, legacy 읽기 가시성(바이트 보존), query-block 비실행, cross-app fixtures가 모두 필수다.
