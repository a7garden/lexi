import Foundation
import GRDB

/// 사전 조회 결과 하나. 특정 개념 + 그 개념의 최신 설명 개정본.
public struct DictionaryEntry: Sendable, Equatable {
    public var conceptId: Int64
    public var preferredTerm: String
    public var field: String?
    public var isFavorite: Bool
    /// 항목(표제어) 언어. concept.lang에서 온다. v2 이전 행은 nil(미상).
    public var termLanguage: EntryLanguage?
    public var revisionId: Int64?
    public var oneLine: String?
    public var easyExplanation: String?
    /// ai | user | nil(개정본 없음)
    public var author: String?
    /// 설명 개정본의 언어. 개정본이 없거나 v2 이전 미상이면 nil.
    public var explanationLanguage: EntryLanguage?

    public init(
        conceptId: Int64,
        preferredTerm: String,
        field: String?,
        isFavorite: Bool,
        termLanguage: EntryLanguage? = nil,
        revisionId: Int64? = nil,
        oneLine: String? = nil,
        easyExplanation: String? = nil,
        author: String? = nil,
        explanationLanguage: EntryLanguage? = nil
    ) {
        self.conceptId = conceptId
        self.preferredTerm = preferredTerm
        self.field = field
        self.isFavorite = isFavorite
        self.termLanguage = termLanguage
        self.revisionId = revisionId
        self.oneLine = oneLine
        self.easyExplanation = easyExplanation
        self.author = author
        self.explanationLanguage = explanationLanguage
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
    public let database: AppDatabase
    public init(database: AppDatabase) {
        self.database = database
    }

    /// 정확 일치 조회. 저장된 설명이 있으면 AI 호출 없이 그대로 돌려준다.
    ///
    /// `revisionLang`을 주면 그 언어로 쓰인 개정본 중 최신 것을 우선한다. 해당 언어의
    /// 개정본이 없으면 언어와 무관한 최신 개정본을 보여준다(빈 결과보다 낫다).
    public func lookupExact(
        _ rawQuery: String,
        revisionLang: EntryLanguage? = nil
    ) async throws -> [DictionaryEntry] {
        let query = normalize(rawQuery)
        guard !query.isEmpty else { return [] }
        let revisionPicker = revisionLang == nil
            ? "(SELECT MAX(id) FROM definitionRevision WHERE conceptId = c.id)"
            : """
              (SELECT id FROM definitionRevision WHERE conceptId = c.id
               ORDER BY COALESCE(lang = ?, 0) DESC, id DESC LIMIT 1)
              """
        var builder = StatementArguments()
        if let revisionLang { builder += [revisionLang.rawValue] }
        builder += [query]
        let arguments = builder
        return try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.id AS conceptId, c.preferredTerm, c.field, c.isFavorite,
                       c.lang AS termLang,
                       d.id AS revisionId, d.oneLine, d.easyExplanation, d.author,
                       d.lang AS revisionLang
                FROM alias a
                JOIN concept c ON c.id = a.conceptId
                LEFT JOIN definitionRevision d
                  ON d.conceptId = c.id
                 AND d.id = \(revisionPicker)
                WHERE a.text = ?
                ORDER BY c.id
                """, arguments: arguments)
            return rows.map { row in
                DictionaryEntry(
                    conceptId: row["conceptId"],
                    preferredTerm: row["preferredTerm"],
                    field: row["field"],
                    isFavorite: row["isFavorite"],
                    termLanguage: EntryLanguage.decode(row["termLang"]),
                    revisionId: row["revisionId"],
                    oneLine: row["oneLine"],
                    easyExplanation: row["easyExplanation"],
                    author: row["author"],
                    explanationLanguage: EntryLanguage.decode(row["revisionLang"])
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
                sql: "INSERT INTO lookupRecord (query, conceptId, status, lookedUpAt) VALUES (?, ?, ?, ?)",
                arguments: [query, conceptId, status.rawValue, Date.now]
            )
        }
    }

    /// 새 개념 저장 (표제어 + 별칭 + 첫 설명). 조회 결과가 없을 때 AI 생성 결과를 받는 자리.
    ///
    /// 언어를 주지 않으면 각 텍스트에서 추정한다. 표제어 언어가 concept.lang과 별칭의
    /// 기본 후보가 되고, 별칭은 별칭 텍스트 각각의 언어로 기록한다(PDC의 alias
    /// text+language 일치에 쓰인다). alias.lang은 v1부터 NOT NULL이므로 별칭 추정에
    /// 실패하면 표제어 언어를 따르고 그마저 없으면 앱 기본 언어인 'ko'를 쓴다.
    /// concept·개정본은 NULL(미상)을 허용한다.
    @discardableResult
    public func saveConcept(
        preferredTerm: String,
        aliases: [String],
        field: String?,
        oneLine: String,
        easyExplanation: String,
        author: String,
        provider: String?,
        termLanguage: EntryLanguage? = nil,
        explanationLanguage: EntryLanguage? = nil
    ) async throws -> Int64 {
        let term = normalize(preferredTerm)
        precondition(!term.isEmpty, "표제어는 비어 있을 수 없다")
        let termLang = termLanguage ?? LanguageDetector.detect(term)
        let explanationLang = explanationLanguage
            ?? LanguageDetector.detect(oneLine + " " + easyExplanation)
        return try await database.writer.write { db in
            let conceptId = try Int64.fetchOne(
                db,
                sql: "INSERT INTO concept (preferredTerm, field, lang, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?) RETURNING id",
                arguments: [term, field, termLang?.rawValue, Date.now, Date.now]
            )!
            var texts = aliases.map { normalize($0) }.filter { !$0.isEmpty }
            if !texts.contains(term) { texts.append(term) }
            for text in Set(texts) {
                let aliasLang = LanguageDetector.detect(text) ?? termLang ?? .korean
                try db.execute(
                    sql: "INSERT OR IGNORE INTO alias (conceptId, text, lang) VALUES (?, ?, ?)",
                    arguments: [conceptId, text, aliasLang.rawValue]
                )
            }
            try db.execute(
                sql: """
                INSERT INTO definitionRevision (conceptId, oneLine, easyExplanation, author, provider, lang, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [conceptId, oneLine, easyExplanation, author, provider, explanationLang?.rawValue, Date.now]
            )
            return conceptId
        }
    }

    /// 보수적 정규화: 앞뒤 공백만 정리. 대소문자·기호는 의미를 구분할 수 있으므로 보존.
    func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
    }

    /// 개정본에 출처를 연결한다. 앱이 실제로 가져온 자료만 저장한다(모델이 지어낸 URL 금지).
    public func addSource(revisionId: Int64, title: String, url: String?, excerpt: String?) async throws {
        _ = try await database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO sourceRef (revisionId, title, url, excerpt, retrievedAt) VALUES (?, ?, ?, ?, ?)",
                arguments: [revisionId, title, url, excerpt, Date.now]
            )
        }
    }
}
