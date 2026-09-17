import Foundation
import GRDB

// MARK: - 통계 화면 읽기 모델

/// 저장 상태 요약. 모든 수치는 한 번의 읽기 트랜잭션에서 나온 스냅샷이다.
public struct LibraryStatsOverview: Sendable, Equatable {
    public var conceptCount: Int
    public var aliasCount: Int
    public var revisionCount: Int
    public var sourceCount: Int
    public var favoriteCount: Int
    /// author가 ai인 개정본 수(최신 여부와 무관한 누적).
    public var aiRevisionCount: Int
    /// author가 user인 개정본 수.
    public var userRevisionCount: Int
    /// 조회 기록 전체. hit·miss를 모두 포함한다.
    public var totalLookups: Int
    public var hitLookups: Int
    public var missLookups: Int
    /// 조회 기록이 하나라도 있는 서로 다른 개념 수.
    public var lookedConceptCount: Int
    /// 조회 기록이 2회 이상인 개념 수(재조회).
    public var revisitedConceptCount: Int
    public var firstSavedAt: Date?
    public var lastSavedAt: Date?
    public var lastLookupAt: Date?

    /// 재조회률: 조회된 개념 중 2회 이상 다시 찾아본 비율. 조회된 개념이 없으면 nil.
    public var revisitRate: Double? {
        lookedConceptCount > 0
            ? Double(revisitedConceptCount) / Double(lookedConceptCount)
            : nil
    }

    /// 조회된 개념 하나당 평균 조회 수. 조회된 개념이 없으면 nil.
    public var averageLookupsPerLookedConcept: Double? {
        lookedConceptCount > 0
            ? Double(hitLookups) / Double(lookedConceptCount)
            : nil
    }
}

/// 조회 수 순위 한 줄. 순위·복습 목록이 같은 모양을 공유한다.
public struct WordRank: Sendable, Equatable, Identifiable {
    public var conceptId: Int64
    public var term: String
    public var field: String?
    public var lookupCount: Int
    public var lastLookedUpAt: Date

    public var id: Int64 { conceptId }
}

/// 저장된 개념에 닿지 못한 검색어 한 줄.
public struct MissedQuery: Sendable, Equatable, Identifiable {
    public var query: String
    public var count: Int
    public var lastAttemptedAt: Date

    public var id: String { query }
}

/// 하루 단위 활동. day는 현지 시간대의 날짜 시작 시각이다.
public struct StatsDayPoint: Sendable, Equatable, Identifiable {
    public var day: Date
    /// 그날의 조회 기록 수(hit·miss 포함).
    public var lookups: Int
    /// 그날 저장된 개념 수.
    public var saved: Int

    public var id: Date { day }
}

/// 시간대별 조회 수 한 칸(0…23시).
public struct StatsHourCount: Sendable, Equatable, Identifiable {
    public var hour: Int
    public var lookups: Int

    public var id: Int { hour }
}

/// 이름(언어·분야 등)별 개수.
public struct StatsNameCount: Sendable, Equatable, Identifiable {
    public var name: String
    public var count: Int

    public var id: String { name }
}

/// 통계 화면 스냅샷. 순위 목록은 상위 일부만 담는다.
public struct LibraryStats: Sendable, Equatable {
    /// 상위 조회 순위 개수.
    public static let topWordLimit = 8
    /// 오래된 조회 순위(복습 후보) 개수.
    public static let neglectedWordLimit = 5
    /// 상위 놓친 검색어 개수.
    public static let missedQueryLimit = 8
    /// 일별 활동 기본 길이(오늘 포함 과거 방향).
    public static let defaultDailyWindow = 30

    public var overview: LibraryStatsOverview
    public var topWords: [WordRank]
    /// 마지막 조회가 가장 오래된 개념(복습 후보). 2회 이상 조회된 개념만 담는다.
    public var neglectedWords: [WordRank]
    public var missedQueries: [MissedQuery]
    /// 오늘부터 과거 방향 `dailyWindow`일. 기록이 없는 날은 0으로 채운다.
    public var daily: [StatsDayPoint]
    /// 0시부터 23시까지 시간대별 조회 수.
    public var hourly: [StatsHourCount]
    /// 개념 표제어 언어 분포. 미상은 "미상"으로 표기한다.
    public var languages: [StatsNameCount]
    /// 개념 분야 분포. 분야가 없으면 "분야 없음"으로 표기한다.
    public var fields: [StatsNameCount]
}

// MARK: - 통계 조회

extension LookupService {
    /// 통계 화면용 스냅샷. 읽기 전용이며 저장 상태를 바꾸지 않는다.
    ///
    /// - Parameters:
    ///   - now: 일별·시간대별 버킷의 기준 시각. 테스트에서 고정한다.
    ///   - dailyWindow: 일별 활동 길이(일). 오늘을 포함해 과거 방향으로 센다.
    public func libraryStats(
        now: Date = Date(),
        dailyWindow: Int = LibraryStats.defaultDailyWindow
    ) async throws -> LibraryStats {
        try await database.writer.read { db in
            func count(_ sql: String, _ arguments: StatementArguments = StatementArguments()) throws -> Int {
                try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
            }
            func date(_ sql: String) throws -> Date? {
                try Date.fetchOne(db, sql: sql)
            }

            let overview = LibraryStatsOverview(
                conceptCount: try count("SELECT COUNT(*) FROM concept"),
                aliasCount: try count("SELECT COUNT(*) FROM alias"),
                revisionCount: try count("SELECT COUNT(*) FROM definitionRevision"),
                sourceCount: try count("SELECT COUNT(*) FROM sourceRef"),
                favoriteCount: try count("SELECT COUNT(*) FROM concept WHERE isFavorite = 1"),
                aiRevisionCount: try count("SELECT COUNT(*) FROM definitionRevision WHERE author = 'ai'"),
                userRevisionCount: try count("SELECT COUNT(*) FROM definitionRevision WHERE author = 'user'"),
                totalLookups: try count("SELECT COUNT(*) FROM lookupRecord"),
                hitLookups: try count("SELECT COUNT(*) FROM lookupRecord WHERE status = 'hit'"),
                missLookups: try count("SELECT COUNT(*) FROM lookupRecord WHERE status = 'miss'"),
                lookedConceptCount: try count("""
                    SELECT COUNT(DISTINCT conceptId) FROM lookupRecord WHERE conceptId IS NOT NULL
                    """),
                revisitedConceptCount: try count("""
                    SELECT COUNT(*) FROM (SELECT conceptId FROM lookupRecord
                                          WHERE conceptId IS NOT NULL
                                          GROUP BY conceptId HAVING COUNT(*) >= 2)
                    """),
                firstSavedAt: try date("SELECT MIN(createdAt) FROM concept"),
                lastSavedAt: try date("SELECT MAX(createdAt) FROM concept"),
                lastLookupAt: try date("SELECT MAX(lookedUpAt) FROM lookupRecord")
            )

            // 조회 순위: 조회 수 DESC, 그다음 최근 조회가 새로운 것, id가 큰 것(최근 저장).
            let rankSQL = """
                SELECT l.conceptId AS conceptId, c.preferredTerm, c.field,
                       COUNT(*) AS lookupCount, MAX(l.lookedUpAt) AS lastLookedUpAt
                FROM lookupRecord l
                JOIN concept c ON c.id = l.conceptId
                GROUP BY l.conceptId
                """
            let rankOrder = " ORDER BY lookupCount DESC, lastLookedUpAt DESC, l.conceptId DESC LIMIT ?"
            let topWords = try WordRank.fetchAll(
                db, sql: rankSQL + rankOrder,
                arguments: [LibraryStats.topWordLimit]
            )
            // 복습 후보: 2회 이상 본 개념 중 가장 오래 안 본 것부터.
            let neglectedWords = try WordRank.fetchAll(
                db,
                sql: rankSQL + " HAVING COUNT(*) >= 2 ORDER BY lastLookedUpAt ASC, lookupCount DESC, l.conceptId DESC LIMIT ?",
                arguments: [LibraryStats.neglectedWordLimit]
            )
            let missedQueries = try MissedQuery.fetchAll(
                db,
                sql: """
                    SELECT query, COUNT(*) AS count, MAX(lookedUpAt) AS lastAttemptedAt
                    FROM lookupRecord
                    WHERE status = 'miss'
                    GROUP BY query
                    ORDER BY count DESC, lastAttemptedAt DESC
                    LIMIT ?
                    """,
                arguments: [LibraryStats.missedQueryLimit]
            )

            // 일별·시간대별 버킷은 현지 시간대 경계가 기준이라 SQLite 대신 Swift에서 묶는다.
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: now)
            var lookupsByOffset: [Int: Int] = [:]
            var hourly = [Int](repeating: 0, count: 24)
            let lookupDates = try Date.fetchAll(db, sql: "SELECT lookedUpAt FROM lookupRecord")
            for lookedUpAt in lookupDates {
                let startOfDay = calendar.startOfDay(for: lookedUpAt)
                let offset = calendar.dateComponents([.day], from: startOfDay, to: today).day ?? 0
                if offset >= 0, offset < dailyWindow {
                    lookupsByOffset[offset, default: 0] += 1
                }
                hourly[calendar.component(.hour, from: lookedUpAt)] += 1
            }
            var savedByOffset: [Int: Int] = [:]
            let savedDates = try Date.fetchAll(db, sql: "SELECT createdAt FROM concept")
            for createdAt in savedDates {
                let startOfDay = calendar.startOfDay(for: createdAt)
                let offset = calendar.dateComponents([.day], from: startOfDay, to: today).day ?? 0
                if offset >= 0, offset < dailyWindow {
                    savedByOffset[offset, default: 0] += 1
                }
            }
            let daily = (0..<dailyWindow).reversed().map { offset -> StatsDayPoint in
                StatsDayPoint(
                    day: calendar.date(byAdding: .day, value: -offset, to: today) ?? today,
                    lookups: lookupsByOffset[offset] ?? 0,
                    saved: savedByOffset[offset] ?? 0
                )
            }

            func nameCounts(_ sql: String, naming: (String?) -> String) throws -> [StatsNameCount] {
                try Row.fetchAll(db, sql: sql).map { row in
                    StatsNameCount(name: naming(row["value"]), count: row["count"])
                }
            }
            // 개념 언어 태그는 지원 언어 한국어 표기로, 분야는 원문 그대로 표기한다.
            let languages = try nameCounts("""
                SELECT COALESCE(lang, '') AS value, COUNT(*) AS count
                FROM concept GROUP BY lang
                ORDER BY count DESC, value ASC
                """) { raw in raw.flatMap { EntryLanguage.decode($0)?.koreanName } ?? "미상" }
            let fields = try nameCounts("""
                SELECT COALESCE(field, '') AS value, COUNT(*) AS count
                FROM concept GROUP BY field
                ORDER BY count DESC, value ASC
                """) { raw in (raw?.isEmpty == false ? raw : nil) ?? "분야 없음" }

            return LibraryStats(
                overview: overview,
                topWords: topWords,
                neglectedWords: neglectedWords,
                missedQueries: missedQueries,
                daily: daily,
                hourly: hourly.enumerated().map { StatsHourCount(hour: $0.offset, lookups: $0.element) },
                languages: languages,
                fields: fields
            )
        }
    }
}

// MARK: - GRDB 행 매핑

extension WordRank: FetchableRecord {
    public init(row: Row) {
        self.init(
            conceptId: row["conceptId"],
            term: row["preferredTerm"],
            field: row["field"],
            lookupCount: row["lookupCount"],
            lastLookedUpAt: row["lastLookedUpAt"]
        )
    }
}

extension MissedQuery: FetchableRecord {
    public init(row: Row) {
        self.init(
            query: row["query"],
            count: row["count"],
            lastAttemptedAt: row["lastAttemptedAt"]
        )
    }
}
