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
    /// lookupRecord 총 행수(hit + miss).
    public var recentLookups: Int

    public init(all: Int, favorites: Int, aiGenerated: Int, userEdited: Int, recentLookups: Int) {
        self.all = all
        self.favorites = favorites
        self.aiGenerated = aiGenerated
        self.userEdited = userEdited
        self.recentLookups = recentLookups
    }
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

// MARK: - 라이브러리 조회·관리

extension LookupService {
    /// 부분일치 필터. 검색어 자리 3개(표제어, 한 줄 요약, 별칭).
    private static let searchFilter = """
        WHERE c.preferredTerm LIKE ? ESCAPE '\\'
           OR d.oneLine LIKE ? ESCAPE '\\'
           OR EXISTS (SELECT 1 FROM alias a WHERE a.conceptId = c.id AND a.text LIKE ? ESCAPE '\\')
        """

    /// 라이브러리 요약 카운트. ai/user 구분은 **최신 개정본** author 기준이다.
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
                recentLookups: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lookupRecord") ?? 0
            )
        }
    }

    /// 라이브러리 목록. 검색어가 있으면 표제어·별칭·한 줄 요약 부분일치(LIKE, ASCII 대소문자 무시).
    /// 검색어의 %, _, \는 와일드카드가 아니라 문자 그대로 취급한다. 정렬은 updatedAt DESC.
    public func listLibrary(search: String = "", limit: Int = 500) async throws -> [LibraryItem] {
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
        let tail = " ORDER BY c.updatedAt DESC, c.id DESC LIMIT ?"
        return try await database.writer.read { db in
            let rows: [Row]
            if term.isEmpty {
                rows = try Row.fetchAll(db, sql: baseSQL + tail, arguments: [limit])
            } else {
                let pattern = "%" + likeEscaped(term) + "%"
                rows = try Row.fetchAll(
                    db,
                    sql: baseSQL + Self.searchFilter + tail,
                    arguments: [pattern, pattern, pattern, limit]
                )
            }
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

    /// 개념 상세: 최신 개정본 entry + 그 개정본의 출처(retrievedAt DESC) + 조회 기록(최신순, 최대 100).
    /// 개념이 없으면 nil.
    public func entryDetail(conceptId: Int64) async throws -> (entry: DictionaryEntry, sources: [SourceItem], history: [HistoryItem])? {
        try await database.writer.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT c.id AS conceptId, c.preferredTerm, c.field, c.isFavorite,
                       d.id AS revisionId, d.oneLine, d.easyExplanation, d.author
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
                revisionId: row["revisionId"],
                oneLine: row["oneLine"],
                easyExplanation: row["easyExplanation"],
                author: row["author"]
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
            try db.execute(
                sql: "UPDATE concept SET isFavorite = ?, updatedAt = ? WHERE id = ?",
                arguments: [favorite, Date.now, conceptId]
            )
        }
    }

    /// 사용자 개정본을 추가한다(기존 개정본을 덮어쓰지 않음) + concept.updatedAt 갱신.
    public func saveUserRevision(conceptId: Int64, oneLine: String, easyExplanation: String) async throws {
        _ = try await database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO definitionRevision (conceptId, oneLine, easyExplanation, author) VALUES (?, ?, ?, 'user')",
                arguments: [conceptId, oneLine, easyExplanation]
            )
            try db.execute(
                sql: "UPDATE concept SET updatedAt = ? WHERE id = ?",
                arguments: [Date.now, conceptId]
            )
        }
    }

    /// 개념 삭제. 별칭·개정본·출처는 FK cascade로 함께 삭제되고, 조회 기록 행은 남고 conceptId만 NULL이 된다.
    public func deleteConcept(conceptId: Int64) async throws {
        _ = try await database.writer.write { db in
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
