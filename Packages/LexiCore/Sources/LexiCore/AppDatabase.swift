import Foundation
import GRDB

/// 앱의 로컬 사전 데이터베이스.
///
/// 스키마 설계: 표현(별칭) → 개념 → 설명 개정본. 출처·조회 기록은 개념/개정본에 연결된다.
/// "저장했다"와 "검증했다"는 다른 상태이므로 author(ai/user)와 source_ref를 분리해 둔다.
public struct AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// 실제 사용: ~/Library/Application Support/Lexi/lexi.sqlite
    public static func makeDefault() throws -> AppDatabase {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Lexi", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("lexi.sqlite")
        return AppDatabase(writer: try DatabasePool(path: dbURL.path))
    }

    /// 테스트·프리뷰용 인메모리 DB.
    public static func makeInMemory() throws -> AppDatabase {
        AppDatabase(writer: try DatabaseQueue())
    }

    public func migrate() throws {
        try Self.makeMigrator().migrate(writer)
    }

    /// 앱이 사용하는 전체 마이그레이션. up-test에서 부분 적용(`migrate(_:upTo:)`)에 쓴다.
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "concept") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("preferredTerm", .text).notNull()
                t.column("field", .text)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull().defaults(to: Date.now)
                t.column("updatedAt", .datetime).notNull().defaults(to: Date.now)
            }

            try db.create(table: "alias") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conceptId", .integer)
                    .notNull()
                    .references("concept", onDelete: .cascade)
                t.column("text", .text).notNull()
                t.column("lang", .text).notNull().defaults(to: "ko")
                t.uniqueKey(["conceptId", "text", "lang"])
            }
            try db.create(indexOn: "alias", columns: ["text"])

            try db.create(table: "definitionRevision") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conceptId", .integer)
                    .notNull()
                    .references("concept", onDelete: .cascade)
                t.column("oneLine", .text).notNull()
                t.column("easyExplanation", .text).notNull()
                // author: ai | user — AI 재조사는 새 개정본을 만들 뿐 user 개정본을 덮어쓰지 않는다.
                t.column("author", .text).notNull()
                // provider: "ollama:llama3.1:8b" 같은 생성 주체 식별자. user 개정본이면 nil.
                t.column("provider", .text)
                t.column("createdAt", .datetime).notNull().defaults(to: Date.now)
            }

            try db.create(table: "sourceRef") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("revisionId", .integer)
                    .notNull()
                    .references("definitionRevision", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("url", .text)
                t.column("excerpt", .text)
                t.column("retrievedAt", .datetime).notNull().defaults(to: Date.now)
            }

            try db.create(table: "lookupRecord") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("query", .text).notNull()
                t.column("conceptId", .integer).references("concept", onDelete: .setNull)
                // status: hit | miss
                t.column("status", .text).notNull()
                t.column("lookedUpAt", .datetime).notNull().defaults(to: Date.now)
            }
        }
        migrator.registerMigration("v2") { db in
            // 다국어 지원: 개념·개정본에 언어 태그를 추가한다. NULL은 "미상"이고 PDC `lang`의 소스다.
            try db.alter(table: "concept") { t in
                t.add(column: "lang", .text)
            }
            try db.alter(table: "definitionRevision") { t in
                t.add(column: "lang", .text)
            }
            // 기존 행은 저장된 텍스트에서 언어를 추정해 되메운다. 설명은 문장 단위라 추정이
            // 신뢰할 만하고, 추정 실패는 NULL(미상)로 남아 잘못된 표기를 강요하지 않는다.
            let concepts = try Row.fetchAll(db, sql: "SELECT id, preferredTerm FROM concept")
            for row in concepts {
                if let lang = LanguageDetector.detect(row["preferredTerm"] as String) {
                    try db.execute(
                        sql: "UPDATE concept SET lang = ? WHERE id = ?",
                        arguments: [lang.rawValue, row["id"] as Int64]
                    )
                }
            }
            let revisions = try Row.fetchAll(
                db, sql: "SELECT id, oneLine, easyExplanation FROM definitionRevision")
            for row in revisions {
                let text = (row["oneLine"] as String) + " " + (row["easyExplanation"] as String)
                if let lang = LanguageDetector.detect(text) {
                    try db.execute(
                        sql: "UPDATE definitionRevision SET lang = ? WHERE id = ?",
                        arguments: [lang.rawValue, row["id"] as Int64]
                    )
                }
            }
        }
        migrator.registerMigration("v3") { db in
            // iCloud 동기화: 각 행에 동기화 UUID(행 수준 안정 식별자)를 부여하고
            // 미전송 변경 저널·미적용 원격 변경 대기열을 둔다.
            // 이 UUID는 SQLite autoincrement ID와 PDC 문서 ID(pdc_document_map, 별도 마이그레이션)와
            // 무관한 내부 동기화 식별자다. 기존 행은 마이그레이션 때 한 번 채워 다시 바뀌지 않는다.
            try db.alter(table: "concept") { t in
                t.add(column: "uuid", .text)
            }
            try db.alter(table: "alias") { t in
                t.add(column: "uuid", .text)
            }
            try db.alter(table: "definitionRevision") { t in
                t.add(column: "uuid", .text)
            }
            try db.alter(table: "sourceRef") { t in
                t.add(column: "uuid", .text)
            }
            for table in ["concept", "alias", "definitionRevision", "sourceRef"] {
                let rows = try Row.fetchAll(db, sql: "SELECT id FROM \(table) WHERE uuid IS NULL")
                for row in rows {
                    try db.execute(
                        sql: "UPDATE \(table) SET uuid = ? WHERE id = ?",
                        arguments: [UUIDv7.generate().uuidString, row["id"] as Int64]
                    )
                }
                try db.execute(sql: "CREATE UNIQUE INDEX \(table)_uuid_idx ON \(table)(uuid)")
            }

            // 미전송 변경 대기열. (uuid, kind)별로 최신 op 하나만 유지한다.
            // op: upsert | delete. ack 후 삭제되므로 테이블은 대기 중인 변경만 담는다.
            try db.create(table: "syncJournal") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("uuid", .text).notNull()
                t.column("kind", .text).notNull()  // concept | revision | alias | source
                t.column("op", .text).notNull()  // upsert | delete
                t.column("changedAt", .datetime).notNull().defaults(to: Date.now)
                t.uniqueKey(["uuid", "kind"])
            }
            // 부모보다 먼저 도착한 원격 변경의 임시 보관함(의존성 역순 도착 대응).
            // payload는 동기화 행 스냅샷의 JSON이다.
            try db.create(table: "syncPendingRemote") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("uuid", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("payload", .text).notNull()
                t.column("createdAt", .datetime).notNull().defaults(to: Date.now)
                t.uniqueKey(["uuid", "kind"])
            }
            // 동기화 엔진 메타(최초 전체 업로드 완료 플래그 등). 정본 데이터가 아니다.
            try db.create(table: "syncMeta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
        return migrator
    }
}
