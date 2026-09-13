# PDC 채택·마이그레이션 계획

상태: 최우선 상호운용성 어댑터 계획 · 구현 대기  
외부 계약: `pdc-document/1`, corpus revision 3  
목표 역할: 명시적 PDC import/export adapter; Lexi 자체는 vault editor가 아님

Lexi의 내부 정본은 계속 `lexi.sqlite`다. PDC는 사용자가 사전 항목을 다른 앱에서 보거나 다른 앱의 문서를 사전 항목으로 가져오려고 명시적으로 선택할 때만 사용하는 어댑터 계약이다.

## 불변 조건

1. PDC 없이도 조회, 생성, 편집, 개정 이력, 출처 기능이 모두 동작한다.
2. export는 SQLite 정본을 바꾸지 않는 파생 파일 생성이다.
3. import는 기존 사용자 개정본을 덮어쓰거나 AI 초안으로 바꾸지 않는다.
4. `author`의 `ai`/`user` 구분, provider, 출처, 별칭, 언어, 즐겨찾기, 개정 순서를 보존한다.
5. `lookupRecord` 같은 행동 기록은 사용자 문서 내용이 아니므로 export하지 않는다.
6. import/export는 사용자 명시 동작이며 백그라운드 자동 동기화가 아니다.

## 목표 표현

### Export

- 사전 concept 하나를 PDC 문서 하나로 내보낸다.
- 기본 profile은 `pdc-djot/1`이다. 향후 사용자가 HTML 레이아웃을 선택할 때만 `pdc-html/1` export를 추가한다.
- `title`은 preferred term, `lang`은 항목 언어, `aliases`는 표준 필드, `favorite`는 즐겨찾기로 매핑한다.
- 최신 사용자 정의와 읽기 쉬운 개정 이력·출처를 본문에 기록한다.
- 전체 revision/provenance 구조는 `x_lexi.revision_history_json`에 opaque JSON 문자열로 보존하며 다른 앱은 그대로 왕복한다.

### Stable identity

- SQLite autoincrement ID는 PDC 문서 ID가 아니다.
- 첫 export 때 UUIDv7을 할당하고 `pdc_document_map(concept_id, pdc_document_id)`에 영구 저장한다.
- 같은 concept의 반복 export는 동일 PDC UUID를 사용한다.
- legacy concept ID는 필요할 때 `x_lexi.legacy_id`로 보존한다.
- 매핑 테이블 추가는 정상적인 GRDB schema migration과 이전-version up-test를 동반한다.

### Import

- `.djot`과 PDC-marked `.html`의 공통 envelope와 안전한 텍스트 projection을 읽는다.
- unmarked HTML, unsupported profile, unsafe HTML, malformed envelope는 자동 가져오지 않고 진단한다.
- PDC UUID 매핑이 있으면 해당 concept를 대상으로 한다. 없으면 정확한 alias/text+language 일치를 제안하되 자동 병합하지 않는다.
- 새 내용은 새로운 `definitionRevision`으로만 추가한다.
- 동일 revision payload digest가 이미 존재하면 멱등하게 건너뛴다.
- 충돌·모호성·필드 손실을 preview한 뒤 사용자가 확정한다.

## 단계

### Stage 0 — fixture와 매핑 고정

- corpus revision 3을 LexiCore 테스트 fixture로 연결한다.
- `x_lexi` JSON schema, 본문 layout, revision digest, UUID mapping migration을 문서와 테스트로 고정한다.

완료 조건: 동일 입력이 항상 동일 export 계획과 import preview를 만든다.

### Stage 1 — 순수 codec

- LexiCore에 파일 I/O가 없는 envelope/profile parser와 Djot writer를 추가한다.
- 두 body profile에서 안전한 표시 텍스트를 추출한다.
- unknown fields/extensions를 보존하거나 import 계획에서 명시적으로 unsupported 처리한다.

완료 조건: corpus 분류와 encode/decode round trip이 Swift 테스트에서 통과한다.

### Stage 2 — stable UUID와 export

- GRDB mapping table migration과 up-test를 추가한다.
- 사용자가 선택한 concept를 새 `.djot` target으로 export한다.
- 기존 파일 overwrite 전에는 source digest와 expected target state를 검증한다.

완료 조건: 반복 export가 같은 UUID를 사용하며 SQLite 내용은 변하지 않는다.

### Stage 3 — preview-first import

- import plan UI에 대상 concept, 생성될 revision, aliases, sources, conflicts를 표시한다.
- 사용자 확정 뒤 하나의 DB transaction으로 새 revision과 매핑을 기록한다.
- 같은 파일 재-import는 중복 revision을 만들지 않는다.

완료 조건: AI/사용자 author 구분과 기존 revision이 모든 fixture에서 보존된다.

### Stage 4 — 교차 앱 검증

- Oximemo와 Sawhorse가 Lexi export를 동일 ID·제목·별칭·본문으로 읽는지 검증한다.
- Lexi가 두 앱의 대표 Djot/HTML 문서를 안전하게 preview하고 선택적으로 가져오는지 검증한다.

완료 조건: corpus revision 3과 공통 representative-vault suite가 모두 통과한다.

## 비목표

- SQLite를 파일 기반 PDC 저장소로 교체하지 않는다.
- Lexi를 범용 vault 브라우저나 문서 편집기로 만들지 않는다.
- 자동 양방향 동기화, background export, path 기반 identity를 만들지 않는다.
- HTML을 Djot으로 자동 변환하지 않는다.
- 행동 기록, 모델 파일, 설정, 캐시를 PDC로 내보내지 않는다.

## 검증

```bash
swift test --package-path Packages/LexiCore
xcodegen generate
xcodebuild -project Lexi.xcodeproj -scheme Lexi -configuration Release CODE_SIGNING_ALLOWED=NO build
```

PDC 기능 구현 시 corpus revision 3, schema up-test, repeated-export identity, repeated-import idempotence, author/provenance preservation, and cross-app fixtures are mandatory.
