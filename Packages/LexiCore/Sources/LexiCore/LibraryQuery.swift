import Foundation
import GRDB

// MARK: - 라이브러리 화면 읽기 모델

/// 라이브러리 상단 요약 카운트.
public struct LibraryCounts: Sendable, Equatable {
    public var all: Int
    public var favorites: Int
    /// 최신 개정본 author가 ai인 개념 수.
    public var aiGenerated: Int
    /// 최신 개정본 author가 user인 개념 수.
    public var userEdited: Int
    /// 최근 조회 카테고리 개념 수: 조회 기록이 하나라도 있는 서로 다른 개념 수.
    public var recentLookups: Int

    public init(all: Int, favorites: Int, aiGenerated: Int, userEdited: Int, recentLookups: Int) {
        self.all = all
        self.favorites = favorites
        self.aiGenerated = aiGenerated
        self.userEdited = userEdited
        self.recentLookups = recentLookups
    }
}

/// 라이브러리 목록 카테고리 필터.
public enum LibraryFilter: String, CaseIterable, Sendable {
    /// 전체.
    case all
    /// 조회 기록이 있는 개념(최근 조회 순).
    case recent
    /// 즐겨찾기.
    case favorites
    /// 최신 개정본 author가 ai인 개념.
    case aiGenerated
    /// 최신 개정본 author가 user인 개념.
    case userEdited
}

/// 라이브러리 목록 한 줄: 개념 + 최신 개정본 요약 + 조회 횟수.
public struct LibraryItem: Sendable, Equatable, Identifiable {
    /// conceptId와 동일.
    public var id: Int64
    public var conceptId: Int64
    public var preferredTerm: String
    public var field: String?
    public var isFavorite: Bool
    /// 최신 개정본의 한 줄 요약. 개정본이 없으면 nil.
    public var oneLine: String?
    /// 최신 개정본 author(ai | user). 개정본이 없으면 nil.
    public var author: String?
    public var updatedAt: Date
    /// 이 개념을 조회한 횟수(lookupRecord 행수).
    public var lookupCount: Int

    public init(
        id: Int64, conceptId: Int64, preferredTerm: String, field: String?, isFavorite: Bool,
        oneLine: String?, author: String?, updatedAt: Date, lookupCount: Int
    ) {
        self.id = id
        self.conceptId = conceptId
        self.preferredTerm = preferredTerm
        self.field = field
        self.isFavorite = isFavorite
        self.oneLine = oneLine
        self.author = author
        self.updatedAt = updatedAt
        self.lookupCount = lookupCount
    }
}

/// 개정본에 달린 출처 한 건.
public struct SourceItem: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var title: String
    public var url: String?
    public var excerpt: String?
    public var retrievedAt: Date

    public init(id: Int64, title: String, url: String?, excerpt: String?, retrievedAt: Date) {
        self.id = id
        self.title = title
        self.url = url
        self.excerpt = excerpt
        self.retrievedAt = retrievedAt
    }
}

/// 개념 조회 기록 한 건.
public struct HistoryItem: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var query: String
    public var lookedUpAt: Date

    public init(id: Int64, query: String, lookedUpAt: Date) {
        self.id = id
        self.query = query
        self.lookedUpAt = lookedUpAt
    }
}

/// 의미 검색용 파생 문서. DB 정본을 수정하거나 외부 포맷에 기록하지 않는다.
struct SemanticLibraryDocument: Sendable {
    var item: LibraryItem
    var sourceText: String
}

// MARK: - 라이브러리 조회·관리

extension LookupService {
    /// 검색 조건(자리표시자 3개: 표제어, 한 줄 요약, 별칭). 카테고리 필터와 AND로 결합된다.
    private static let searchFilter = """
        c.preferredTerm LIKE ? ESCAPE '\\'
        OR d.oneLine LIKE ? ESCAPE '\\'
        OR EXISTS (SELECT 1 FROM alias a WHERE a.conceptId = c.id AND a.text LIKE ? ESCAPE '\\')
        """

    /// 라이브러리 요약 카운트. ai/user 구분은 **최신 개정본** author 기준이고,
    /// recentLookups는 listLibrary(filter: .recent)에 나올 개념 수와 같다.
    public func libraryCounts() async throws -> LibraryCounts {
        try await database.writer.read { db in
            LibraryCounts(
                all: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM concept") ?? 0,
                favorites: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM concept WHERE isFavorite = 1") ?? 0,
                aiGenerated: try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM concept c
                    WHERE (SELECT author FROM definitionRevision WHERE conceptId = c.id ORDER BY id DESC LIMIT 1) = 'ai'
                    """) ?? 0,
                userEdited: try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM concept c
                    WHERE (SELECT author FROM definitionRevision WHERE conceptId = c.id ORDER BY id DESC LIMIT 1) = 'user'
                    """) ?? 0,
                recentLookups: try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM concept c
                    WHERE EXISTS (SELECT 1 FROM lookupRecord WHERE conceptId = c.id)
                    """) ?? 0
            )
        }
    }

    /// 라이브러리 목록. 검색어가 있으면 표제어·별칭·한 줄 요약 부분일치(LIKE, ASCII 대소문자 무시).
    /// 검색어의 %, _, \는 와일드카드가 아니라 문자 그대로 취급한다.
    /// 카테고리 필터는 검색과 AND로 결합되고, limit은 필터 적용 **후**에 잘린다.
    /// 정렬: recent는 개념별 최신 lookedUpAt DESC(동률이면 id DESC), 그 외 updatedAt DESC, id DESC.
    public func listLibrary(
        search: String = "",
        filter: LibraryFilter = .all,
        limit: Int = 500
    ) async throws -> [LibraryItem] {
        let term = normalize(search)
        let baseSQL = """
            SELECT c.id AS conceptId, c.preferredTerm, c.field, c.isFavorite,
                   d.oneLine, d.author, c.updatedAt,
                   (SELECT COUNT(*) FROM lookupRecord WHERE conceptId = c.id) AS lookupCount
            FROM concept c
            LEFT JOIN definitionRevision d
              ON d.conceptId = c.id
             AND d.id = (SELECT MAX(id) FROM definitionRevision WHERE conceptId = c.id)
            """
        // 최신 개정본 author 기준. libraryCounts의 aiGenerated/userEdited와 같은 식이다.
        let latestAuthor =
            "(SELECT author FROM definitionRevision WHERE conceptId = c.id ORDER BY id DESC LIMIT 1)"
        var clauses: [String] = []
        var recentJoin = ""
        var orderBy = " ORDER BY c.updatedAt DESC, c.id DESC"
        let pattern = term.isEmpty ? nil : "%" + likeEscaped(term) + "%"
        if pattern != nil {
            clauses.append("(" + Self.searchFilter + ")")
        }
        switch filter {
        case .all:
            break
        case .recent:
            // 조회 기록이 있는 서로 다른 개념만 남기고, 개념별 최신 조회 시각 순으로 정렬한다.
            recentJoin = """
                JOIN (SELECT conceptId, MAX(lookedUpAt) AS latestLookedUpAt
                      FROM lookupRecord WHERE conceptId IS NOT NULL
                      GROUP BY conceptId) lr ON lr.conceptId = c.id
                """
            orderBy = " ORDER BY lr.latestLookedUpAt DESC, c.id DESC"
        case .favorites:
            clauses.append("c.isFavorite = 1")
        case .aiGenerated:
            clauses.append(latestAuthor + " = 'ai'")
        case .userEdited:
            clauses.append(latestAuthor + " = 'user'")
        }
        let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let sql = baseSQL + recentJoin + whereSQL + orderBy + " LIMIT ?"

        return try await database.writer.read { db in
            var statementArguments = StatementArguments()
            if let pattern {
                statementArguments += [pattern, pattern, pattern]
            }
            statementArguments += [limit]
            let rows = try Row.fetchAll(db, sql: sql, arguments: statementArguments)
            return rows.map { row in
                LibraryItem(
                    id: row["conceptId"],
                    conceptId: row["conceptId"],
                    preferredTerm: row["preferredTerm"],
                    field: row["field"],
                    isFavorite: row["isFavorite"],
                    oneLine: row["oneLine"],
                    author: row["author"],
                    updatedAt: row["updatedAt"],
                    lookupCount: row["lookupCount"]
                )
            }
        }
    }

    /// 현재 필터에 속한 항목의 표제어·분야·별칭·최신 설명을 임베딩 입력으로 투영한다.
    /// 일반 검색과 달리 원문 순위나 저장 상태를 바꾸지 않는 읽기 전용 파생 데이터다.
    func semanticLibraryDocuments(
        filter: LibraryFilter = .all,
        limit: Int = 500
    ) async throws -> [SemanticLibraryDocument] {
        let items = try await listLibrary(search: "", filter: filter, limit: limit)
        guard !items.isEmpty else { return [] }

        return try await database.writer.read { db in
            let placeholders = Array(repeating: "?", count: items.count).joined(separator: ",")
            var arguments = StatementArguments()
            for item in items { arguments += [item.conceptId] }

            let aliasRows = try Row.fetchAll(
                db,
                sql: "SELECT conceptId, text FROM alias WHERE conceptId IN (\(placeholders)) ORDER BY conceptId, id",
                arguments: arguments
            )
            var aliasesByConcept: [Int64: [String]] = [:]
            for row in aliasRows {
                let conceptID: Int64 = row["conceptId"]
                aliasesByConcept[conceptID, default: []].append(row["text"])
            }

            let explanationRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT d.conceptId, d.easyExplanation
                    FROM definitionRevision d
                    WHERE d.conceptId IN (\(placeholders))
                      AND d.id = (SELECT MAX(id) FROM definitionRevision WHERE conceptId = d.conceptId)
                    """,
                arguments: arguments
            )
            let explanations = Dictionary(uniqueKeysWithValues: explanationRows.map { row in
                (row["conceptId"] as Int64, row["easyExplanation"] as String)
            })

            return items.map { item in
                var parts = ["표제어: \(item.preferredTerm)"]
                if let field = item.field, !field.isEmpty { parts.append("분야: \(field)") }
                let aliases = (aliasesByConcept[item.conceptId] ?? [])
                    .filter { $0 != item.preferredTerm }
                if !aliases.isEmpty { parts.append("별칭: \(aliases.joined(separator: ", "))") }
                if let oneLine = item.oneLine, !oneLine.isEmpty { parts.append("한 줄 정의: \(oneLine)") }
                if let easy = explanations[item.conceptId], !easy.isEmpty { parts.append("쉬운 설명: \(easy)") }
                return SemanticLibraryDocument(item: item, sourceText: parts.joined(separator: "\n"))
            }
        }
    }

    /// 개념 상세: 최신 개정본 entry + 그 개정본의 출처(retrievedAt DESC) + 조회 기록(최신순, 최대 100).
    /// 개념이 없으면 nil.
    public func entryDetail(conceptId: Int64) async throws -> (entry: DictionaryEntry, sources: [SourceItem], history: [HistoryItem])? {
        try await database.writer.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT c.id AS conceptId, c.preferredTerm, c.field, c.isFavorite,
                       c.lang AS termLang,
                       d.id AS revisionId, d.oneLine, d.easyExplanation, d.author,
                       d.lang AS revisionLang
                FROM concept c
                LEFT JOIN definitionRevision d
                  ON d.conceptId = c.id
                 AND d.id = (SELECT MAX(id) FROM definitionRevision WHERE conceptId = c.id)
                WHERE c.id = ?
                """, arguments: [conceptId])
            guard let row else { return nil }
            let entry = DictionaryEntry(
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
            let revisionId: Int64? = row["revisionId"]
            let sources: [SourceItem]
            if let revisionId {
                sources = try Row.fetchAll(
                    db,
                    sql: "SELECT id, title, url, excerpt, retrievedAt FROM sourceRef WHERE revisionId = ? ORDER BY retrievedAt DESC, id DESC",
                    arguments: [revisionId]
                ).map { src in
                    SourceItem(
                        id: src["id"],
                        title: src["title"],
                        url: src["url"],
                        excerpt: src["excerpt"],
                        retrievedAt: src["retrievedAt"]
                    )
                }
            } else {
                sources = []
            }
            let history = try Row.fetchAll(
                db,
                sql: "SELECT id, query, lookedUpAt FROM lookupRecord WHERE conceptId = ? ORDER BY lookedUpAt DESC, id DESC LIMIT 100",
                arguments: [conceptId]
            ).map { h in
                HistoryItem(id: h["id"], query: h["query"], lookedUpAt: h["lookedUpAt"])
            }
            return (entry: entry, sources: sources, history: history)
        }
    }

    /// 즐겨찾기 토글. 목록 정렬 기준인 updatedAt도 함께 갱신한다.
    public func setFavorite(conceptId: Int64, _ favorite: Bool) async throws {
        _ = try await database.writer.write { db in
            guard let uuid = try String.fetchOne(
                db, sql: "SELECT uuid FROM concept WHERE id = ?", arguments: [conceptId]
            ) else { return }
            try db.execute(
                sql: "UPDATE concept SET isFavorite = ?, updatedAt = ? WHERE id = ?",
                arguments: [favorite, Date.now, conceptId]
            )
            try SyncJournal.upsert(db, kind: .concept, uuid: uuid)
        }
    }

    /// 사용자 개정본을 추가한다(기존 개정본을 덮어쓰지 않음) + concept.updatedAt 갱신.
    /// 언어를 주지 않으면 작성 텍스트에서 추정한다.
    public func saveUserRevision(
        conceptId: Int64,
        oneLine: String,
        easyExplanation: String,
        language: EntryLanguage? = nil
    ) async throws {
        let lang = language ?? LanguageDetector.detect(oneLine + " " + easyExplanation)
        _ = try await database.writer.write { db in
            guard let conceptUUID = try String.fetchOne(
                db, sql: "SELECT uuid FROM concept WHERE id = ?", arguments: [conceptId]
            ) else { return }
            let revisionUUID = UUIDv7.generate().uuidString
            try db.execute(
                sql: "INSERT INTO definitionRevision (conceptId, oneLine, easyExplanation, author, lang, createdAt, uuid) VALUES (?, ?, ?, 'user', ?, ?, ?)",
                arguments: [conceptId, oneLine, easyExplanation, lang?.rawValue, Date.now, revisionUUID]
            )
            try db.execute(
                sql: "UPDATE concept SET updatedAt = ? WHERE id = ?",
                arguments: [Date.now, conceptId]
            )
            try SyncJournal.upsert(db, kind: .revision, uuid: revisionUUID)
            try SyncJournal.upsert(db, kind: .concept, uuid: conceptUUID)
        }
    }

    /// 개념 삭제. 별칭·개정본·출처는 FK cascade로 함께 삭제되고, 조회 기록 행은 남고 conceptId만 NULL이 된다.
    public func deleteConcept(conceptId: Int64) async throws {
        _ = try await database.writer.write { db in
            guard let conceptUUID = try String.fetchOne(
                db, sql: "SELECT uuid FROM concept WHERE id = ?", arguments: [conceptId]
            ) else { return }
            let aliasUUIDs = try String.fetchAll(
                db, sql: "SELECT uuid FROM alias WHERE conceptId = ? AND uuid IS NOT NULL",
                arguments: [conceptId])
            let revisionRows = try Row.fetchAll(
                db, sql: "SELECT id, uuid FROM definitionRevision WHERE conceptId = ?",
                arguments: [conceptId])
            let revisionIds = revisionRows.map { $0["id"] as Int64 }
            let revisionUUIDs = revisionRows.compactMap { $0["uuid"] as String? }
            var sourceUUIDs: [String] = []
            if !revisionIds.isEmpty {
                let placeholders = String(repeating: "?,", count: revisionIds.count).dropLast()
                sourceUUIDs = try String.fetchAll(
                    db,
                    sql: "SELECT uuid FROM sourceRef WHERE revisionId IN (\(placeholders)) AND uuid IS NOT NULL",
                    arguments: StatementArguments(revisionIds)
                )
            }
            // 실제 삭제 전에 묘비를 남긴다. 부모 삭제가 FK cascade로 자식을 함께 지우므로
            // 자식 묘비도 같은 트랜잭션에서 한 번에 기록한다.
            try SyncJournal.delete(db, kind: .concept, uuid: conceptUUID)
            for uuid in aliasUUIDs { try SyncJournal.delete(db, kind: .alias, uuid: uuid) }
            for uuid in revisionUUIDs { try SyncJournal.delete(db, kind: .revision, uuid: uuid) }
            for uuid in sourceUUIDs { try SyncJournal.delete(db, kind: .source, uuid: uuid) }
            try db.execute(sql: "DELETE FROM concept WHERE id = ?", arguments: [conceptId])
        }
    }

    /// LIKE 패턴용 이스케이프: %, _, \를 문자 그대로 매칭되게 만든다.
    private func likeEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
