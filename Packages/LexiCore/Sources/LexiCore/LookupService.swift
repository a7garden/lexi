import Foundation
import GRDB

/// 사전 조회 결과 하나. 특정 개념 + 그 개념의 최신 설명 개정본.
public struct DictionaryEntry: Sendable, Equatable {
    public var conceptId: Int64
    public var preferredTerm: String
    public var field: String?
    public var isFavorite: Bool
    public var revisionId: Int64?
    public var oneLine: String?
    public var easyExplanation: String?
    /// ai | user | nil(개정본 없음)
    public var author: String?

    public init(
        conceptId: Int64, preferredTerm: String, field: String?, isFavorite: Bool,
        revisionId: Int64?, oneLine: String?, easyExplanation: String?, author: String?
    ) {
        self.conceptId = conceptId
        self.preferredTerm = preferredTerm
        self.field = field
        self.isFavorite = isFavorite
        self.revisionId = revisionId
        self.oneLine = oneLine
        self.easyExplanation = easyExplanation
        self.author = author
    }
}

public enum LookupStatus: String, Sendable {
    case hit
    case miss
}

/// 조회 파이프라인 1단계: 저장된 사전에서 찾기.
///
/// 규칙(설계 문서 준수):
/// - 표제어·별칭 **정확 검색**이 1차. 본문/부분 일치는 이후 마이그레이션에서 확장.
/// - 정규화는 보수적으로: 앞뒤 공백 정리 + 빈 문자열 거부만. 대소문자·기호는 원문 보존.
/// - 같은 표현이 여러 개념(동음이의)을 가리키면 전부 후보로 돌려준다. 앱이 임의로 확정하지 않는다.
public struct LookupService: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// 정확 일치 조회. 저장된 설명이 있으면 AI 호출 없이 그대로 돌려준다.
    public func lookupExact(_ rawQuery: String) async throws -> [DictionaryEntry] {
        let query = normalize(rawQuery)
        guard !query.isEmpty else { return [] }
        return try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.id AS conceptId, c.preferredTerm, c.field, c.isFavorite,
                       d.id AS revisionId, d.oneLine, d.easyExplanation, d.author
                FROM alias a
                JOIN concept c ON c.id = a.conceptId
                LEFT JOIN definitionRevision d
                  ON d.conceptId = c.id
                 AND d.id = (SELECT MAX(id) FROM definitionRevision WHERE conceptId = c.id)
                WHERE a.text = ?
                ORDER BY c.id
                """, arguments: [query])
            return rows.map { row in
                DictionaryEntry(
                    conceptId: row["conceptId"],
                    preferredTerm: row["preferredTerm"],
                    field: row["field"],
                    isFavorite: row["isFavorite"],
                    revisionId: row["revisionId"],
                    oneLine: row["oneLine"],
                    easyExplanation: row["easyExplanation"],
                    author: row["author"]
                )
            }
        }
    }

    /// 조회 기록을 남긴다. hit이면 어떤 개념을 봤는지 함께 기록.
    public func recordLookup(_ rawQuery: String, conceptId: Int64?, status: LookupStatus) async throws {
        let query = normalize(rawQuery)
        guard !query.isEmpty else { return }
        _ = try await database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO lookupRecord (query, conceptId, status) VALUES (?, ?, ?)",
                arguments: [query, conceptId, status.rawValue]
            )
        }
    }

    /// 새 개념 저장 (표제어 + 별칭 + 첫 설명). 조회 결과가 없을 때 AI 생성 결과를 받는 자리.
    @discardableResult
    public func saveConcept(
        preferredTerm: String,
        aliases: [String],
        field: String?,
        oneLine: String,
        easyExplanation: String,
        author: String,
        provider: String?
    ) async throws -> Int64 {
        let term = normalize(preferredTerm)
        precondition(!term.isEmpty, "표제어는 비어 있을 수 없다")
        return try await database.writer.write { db in
            let conceptId = try Int64.fetchOne(
                db,
                sql: "INSERT INTO concept (preferredTerm, field) VALUES (?, ?) RETURNING id",
                arguments: [term, field]
            )!
            var texts = aliases.map { normalize($0) }.filter { !$0.isEmpty }
            if !texts.contains(term) { texts.append(term) }
            for text in Set(texts) {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO alias (conceptId, text) VALUES (?, ?)",
                    arguments: [conceptId, text]
                )
            }
            try db.execute(
                sql: """
                INSERT INTO definitionRevision (conceptId, oneLine, easyExplanation, author, provider)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [conceptId, oneLine, easyExplanation, author, provider]
            )
            return conceptId
        }
    }

    /// 보수적 정규화: 앞뒤 공백만 정리. 대소문자·기호는 의미를 구분할 수 있으므로 보존.
    func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
    }
}
