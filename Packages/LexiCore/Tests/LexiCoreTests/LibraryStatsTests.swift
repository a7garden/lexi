import Testing
import Foundation
@testable import LexiCore

@Suite struct LibraryStatsTests {
    /// 테스트 기준 "오늘": 현지 시간대로 고정한 날짜의 15시.
    private let now: Date = Calendar.current.date(
        from: DateComponents(year: 2026, month: 9, day: 14, hour: 15)
    )!

    private var calendar: Calendar { Calendar.current }

    private func makeService() throws -> LookupService {
        let db = try AppDatabase.makeInMemory()
        try db.migrate()
        return LookupService(database: db)
    }

    /// 시드: RAG(영어, AI 개정본, 분야 AI) / FTS5(한국어, ai → user 개정본, 분야 DB) / tokenizer(미상, user 개정본, 분야 없음).
    private func seedLibrary() async throws -> (service: LookupService, rag: Int64, fts: Int64, tok: Int64) {
        let service = try makeService()
        let rag = try await service.saveConcept(
            preferredTerm: "RAG", aliases: ["검색 증강 생성"], field: "AI",
            oneLine: "외부 지식을 검색해 답을 만든다", easyExplanation: "찾아서 붙여 답한다.",
            author: "ai", provider: "ollama:test", termLanguage: .english
        )
        let fts = try await service.saveConcept(
            preferredTerm: "FTS5", aliases: ["Full-Text Search"], field: "DB",
            oneLine: "SQLite 전문 검색 색인", easyExplanation: "빠르게 찾는 색인.",
            author: "ai", provider: "ollama:test", termLanguage: .korean
        )
        let tok = try await service.saveConcept(
            preferredTerm: "tokenizer", aliases: [], field: nil,
            oneLine: "텍스트를 토큰으로 분할", easyExplanation: "문장을 조각으로.",
            author: "user", provider: nil, termLanguage: nil
        )
        try await service.saveUserRevision(conceptId: fts, oneLine: "SQLite 전문 검색 도구", easyExplanation: "색인으로 빠르게 찾는다.")
        return (service, rag, fts, tok)
    }

    /// 기준 날짜에서 d일 전(0=오늘) h시의 시각.
    private func day(_ d: Int, hour h: Int = 12) -> Date {
        let start = calendar.date(byAdding: .day, value: -d, to: calendar.startOfDay(for: now))!
        return calendar.date(bySettingHour: h, minute: 0, second: 0, of: start)!
    }

    /// 조회 기록을 지정 시각으로 직접 넣는다(recordLookup은 Date.now라 통계 검증에 못 쓴다).
    private func insertLookup(
        _ service: LookupService, conceptId: Int64?, query: String,
        status: String = "hit", at date: Date
    ) async throws {
        try await service.database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO lookupRecord (query, conceptId, status, lookedUpAt) VALUES (?, ?, ?, ?)",
                arguments: [query, conceptId, status, date]
            )
        }
    }

    /// 저장 시각을 고정한다(createdAt은 saveConcept가 Date.now로 기록한다).
    private func setCreatedAt(_ service: LookupService, conceptId: Int64, _ date: Date) async throws {
        try await service.database.writer.write { db in
            try db.execute(sql: "UPDATE concept SET createdAt = ? WHERE id = ?", arguments: [date, conceptId])
        }
    }

    /// 표준 조회 시나리오: RAG 3회, FTS5 2회, tokenizer 1회, miss 3건(asdf 2, qqq 1).
    private func seedLookups(_ service: LookupService, rag: Int64, fts: Int64, tok: Int64) async throws {
        try await insertLookup(service, conceptId: rag, query: "RAG", at: day(1, hour: 9))
        try await insertLookup(service, conceptId: rag, query: "RAG", at: day(0, hour: 10))
        try await insertLookup(service, conceptId: rag, query: "rag", at: day(0, hour: 11))
        try await insertLookup(service, conceptId: fts, query: "FTS5", at: day(5, hour: 9))
        try await insertLookup(service, conceptId: fts, query: "FTS5", at: day(2, hour: 14))
        try await insertLookup(service, conceptId: tok, query: "tokenizer", at: day(3, hour: 20))
        try await insertLookup(service, conceptId: nil, query: "asdf", status: "miss", at: day(1, hour: 13))
        try await insertLookup(service, conceptId: nil, query: "asdf", status: "miss", at: day(0, hour: 13))
        try await insertLookup(service, conceptId: nil, query: "qqq", status: "miss", at: day(1, hour: 14))
    }

    private func stats(
        _ service: LookupService, dailyWindow: Int = LibraryStats.defaultDailyWindow
    ) async throws -> LibraryStats {
        try await service.libraryStats(now: now, dailyWindow: dailyWindow)
    }

    private func almostEqual(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return abs(lhs.timeIntervalSince(rhs)) < 0.5
    }

    // MARK: - 요약

    @Test func overview는_저장_상태와_조회_상태를_정확히_집계한다() async throws {
        let (service, rag, fts, tok) = try await seedLibrary()
        try await seedLookups(service, rag: rag, fts: fts, tok: tok)
        try await setCreatedAt(service, conceptId: rag, day(40))
        try await setCreatedAt(service, conceptId: fts, day(1))
        try await setCreatedAt(service, conceptId: tok, day(0, hour: 9))

        let overview = try await stats(service).overview

        #expect(overview.conceptCount == 3)
        // saveConcept는 표제어 자체를 별칭으로 넣는다: 2 + 2 + 1.
        #expect(overview.aliasCount == 5)
        // 개정본: RAG 1(ai) + FTS5 2(ai, user) + tokenizer 1(user).
        #expect(overview.revisionCount == 4)
        #expect(overview.aiRevisionCount == 2)
        #expect(overview.userRevisionCount == 2)
        #expect(overview.sourceCount == 0)
        #expect(overview.favoriteCount == 0)
        #expect(overview.totalLookups == 9)
        #expect(overview.hitLookups == 6)
        #expect(overview.missLookups == 3)
        #expect(overview.lookedConceptCount == 3)
        // 2회 이상 조회된 개념: RAG(3), FTS5(2).
        #expect(overview.revisitedConceptCount == 2)
        #expect(overview.revisitRate == (2.0 / 3.0))
        #expect(overview.averageLookupsPerLookedConcept == 2.0)
        #expect(almostEqual(overview.firstSavedAt, day(40)))
        #expect(almostEqual(overview.lastSavedAt, day(0, hour: 9)))
        #expect(almostEqual(overview.lastLookupAt, day(0, hour: 13)))
    }

    @Test func overview는_빈_사전에서_0과_nil을_돌려준다() async throws {
        let service = try makeService()

        let stats = try await stats(service)

        #expect(stats.overview.conceptCount == 0)
        #expect(stats.overview.totalLookups == 0)
        #expect(stats.overview.revisitRate == nil)
        #expect(stats.overview.averageLookupsPerLookedConcept == nil)
        #expect(stats.overview.firstSavedAt == nil)
        #expect(stats.overview.lastLookupAt == nil)
        #expect(stats.topWords.isEmpty)
        #expect(stats.missedQueries.isEmpty)
        #expect(stats.languages.isEmpty)
        #expect(stats.daily.count == LibraryStats.defaultDailyWindow)
        #expect(stats.daily.allSatisfy { $0.lookups == 0 && $0.saved == 0 })
        #expect(stats.hourly.count == 24)
        #expect(stats.hourly.allSatisfy { $0.lookups == 0 })
    }

    // MARK: - 순위

    @Test func topWords는_조회수_내림차순_순위다() async throws {
        let (service, rag, fts, tok) = try await seedLibrary()
        try await seedLookups(service, rag: rag, fts: fts, tok: tok)

        let topWords = try await stats(service).topWords

        #expect(topWords.map(\.term) == ["RAG", "FTS5", "tokenizer"])
        #expect(topWords.map(\.lookupCount) == [3, 2, 1])
        // 가장 최근 조회 시각을 함께 돌려준다.
        #expect(almostEqual(topWords[0].lastLookedUpAt, day(0, hour: 11)))
        #expect(topWords[0].field == "AI")
    }

    @Test func topWords는_상위_8개만_담는다() async throws {
        let service = try makeService()
        var ids: [Int64] = []
        for index in 0..<10 {
            let id = try await service.saveConcept(
                preferredTerm: "단어\(index)", aliases: [], field: nil,
                oneLine: "한 줄 \(index)", easyExplanation: "설명 \(index)",
                author: "user", provider: nil, termLanguage: .korean
            )
            ids.append(id)
        }
        // 단어3만 2회, 나머지는 1회. 단어0이 가장 최근.
        for (index, id) in ids.enumerated() {
            try await insertLookup(service, conceptId: id, query: "단어\(index)", at: day(0, hour: index + 1))
        }
        try await insertLookup(service, conceptId: ids[3], query: "단어3", at: day(0, hour: 11))

        let topWords = try await stats(service).topWords

        #expect(topWords.count == LibraryStats.topWordLimit)
        #expect(topWords[0].term == "단어3")
        #expect(topWords[0].lookupCount == 2)
        // 동률이면 최근 조회가 새로운 것부터.
        #expect(topWords[1].term == "단어9")
    }

    @Test func neglectedWords는_2회_이상_본_개념을_가장_오래_안_본_순으로_돌려준다() async throws {
        let (service, rag, fts, tok) = try await seedLibrary()
        try await seedLookups(service, rag: rag, fts: fts, tok: tok)

        let neglected = try await stats(service).neglectedWords

        // 마지막 조회: FTS5(-5일) < tokenizer(-3일, 1회라 제외) < RAG(-1일).
        #expect(neglected.map(\.term) == ["FTS5", "RAG"])
        #expect(neglected[0].lookupCount == 2)
    }

    @Test func missedQueries는_miss_기록만_묶어서_돌려준다() async throws {
        let (service, rag, fts, tok) = try await seedLibrary()
        try await seedLookups(service, rag: rag, fts: fts, tok: tok)

        let missed = try await stats(service).missedQueries

        #expect(missed.map(\.query) == ["asdf", "qqq"])
        #expect(missed.map(\.count) == [2, 1])
        #expect(almostEqual(missed[0].lastAttemptedAt, day(0, hour: 13)))
    }

    // MARK: - 일별·시간대별

    @Test func daily는_오늘부터_30일을_빈_날을_0으로_채워_돌려준다() async throws {
        let (service, rag, fts, tok) = try await seedLibrary()
        try await seedLookups(service, rag: rag, fts: fts, tok: tok) // 오늘 2회, -2일 1회(FTS5), -31일 밖 없음
        try await setCreatedAt(service, conceptId: rag, day(40))     // 창 밖
        try await setCreatedAt(service, conceptId: fts, day(1))      // -1일 저장 1
        try await setCreatedAt(service, conceptId: tok, day(0, hour: 9)) // 오늘 저장 1

        let daily = try await stats(service).daily

        #expect(daily.count == 30)
        #expect(almostEqual(daily.last?.day, calendar.startOfDay(for: now)))
        #expect(daily[0].day == calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)))
        #expect(daily[29].lookups == 3) // 오늘: RAG 두 번 + miss(asdf)
        #expect(daily[29].saved == 1)   // tokenizer
        #expect(daily[28].lookups == 3) // -1일: RAG + miss(asdf, qqq)
        #expect(daily[28].saved == 1)   // -1일: FTS5
        // -5일, -3일, -1일 조회도 창 안에서 세어진다.
        #expect(daily[24].lookups == 1)
        #expect(daily[26].lookups == 1)
    }

    @Test func daily는_창_바깥의_기록을_세지_않는다() async throws {
        let service = try makeService()
        let id = try await service.saveConcept(
            preferredTerm: "오래된단어", aliases: [], field: nil,
            oneLine: "한 줄", easyExplanation: "설명",
            author: "user", provider: nil, termLanguage: .korean
        )
        try await setCreatedAt(service, conceptId: id, day(31))
        try await insertLookup(service, conceptId: id, query: "오래된단어", at: day(31, hour: 8))

        let stats = try await stats(service)

        #expect(stats.overview.lookedConceptCount == 1)
        #expect(stats.daily.allSatisfy { $0.lookups == 0 && $0.saved == 0 })
    }

    @Test func hourly는_0시부터_23시까지_모든_조회를_센다() async throws {
        let (service, rag, fts, tok) = try await seedLibrary()
        try await seedLookups(service, rag: rag, fts: fts, tok: tok)

        let hourly = try await stats(service).hourly

        #expect(hourly.count == 24)
        #expect(hourly.map(\.hour) == Array(0...23))
        // 조회 시각: 9, 10, 11, 9, 14, 20, 13, 13, 14시.
        #expect(hourly[9].lookups == 2)
        #expect(hourly[10].lookups == 1)
        #expect(hourly[11].lookups == 1)
        #expect(hourly[13].lookups == 2)
        #expect(hourly[14].lookups == 2)
        #expect(hourly[20].lookups == 1)
        #expect(hourly.reduce(0) { $0 + $1.lookups } == 9)
    }

    // MARK: - 분포

    @Test func languages와_fields는_개수별로_묶는다() async throws {
        let (service, _, _, _) = try await seedLibrary()

        let stats = try await stats(service)

        #expect(
            Dictionary(uniqueKeysWithValues: stats.languages.map { ($0.name, $0.count) })
                == ["영어": 1, "한국어": 1, "미상": 1]
        )
        #expect(
            Dictionary(uniqueKeysWithValues: stats.fields.map { ($0.name, $0.count) })
                == ["AI": 1, "DB": 1, "분야 없음": 1]
        )
    }

    @Test func languages는_미지원_태그를_미상으로_돌려준다() async throws {
        let service = try makeService()
        try await service.database.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO concept (preferredTerm, field, lang, createdAt, updatedAt)
                VALUES ('mystère', NULL, 'xx', ?, ?)
                """,
                arguments: [now, now]
            )
        }

        let stats = try await stats(service)

        #expect(stats.languages.map(\.name) == ["미상"])
    }
}
