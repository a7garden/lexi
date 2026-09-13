import Testing
import Foundation
@testable import LexiCore

@Suite struct LibraryQueryTests {
    /// 시각 고정 기준점(초 단위라 저장·재조회에서 정확히 보존된다).
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeService() throws -> LookupService {
        let db = try AppDatabase.makeInMemory()
        try db.migrate()
        return LookupService(database: db)
    }

    /// 시드: RAG(ai 개정본 1개) / FTS5(ai → user 개정본) / tokenizer(user 개정본).
    /// updatedAt 고정: FTS5(t+2일) > tokenizer(t+1일) > RAG(t).
    private func seedLibrary() async throws -> (service: LookupService, rag: Int64, fts: Int64, tok: Int64) {
        let service = try makeService()
        let rag = try await service.saveConcept(
            preferredTerm: "RAG", aliases: ["검색 증강 생성"], field: "AI",
            oneLine: "외부 지식을 검색해 답을 만든다", easyExplanation: "찾아서 붙여 답한다.",
            author: "ai", provider: "ollama:test"
        )
        let fts = try await service.saveConcept(
            preferredTerm: "FTS5", aliases: ["Full-Text Search"], field: "DB",
            oneLine: "SQLite 전문 검색 색인", easyExplanation: "빠르게 찾는 색인.",
            author: "ai", provider: "ollama:test"
        )
        let tok = try await service.saveConcept(
            preferredTerm: "tokenizer", aliases: [], field: nil,
            oneLine: "텍스트를 토큰으로 분할", easyExplanation: "문장을 조각으로.",
            author: "user", provider: nil
        )
        try await service.saveUserRevision(conceptId: fts, oneLine: "SQLite 전문 검색 도구", easyExplanation: "색인으로 빠르게 찾는다.")
        try await setUpdatedAt(service, conceptId: rag, base)
        try await setUpdatedAt(service, conceptId: tok, base.addingTimeInterval(86_400))
        try await setUpdatedAt(service, conceptId: fts, base.addingTimeInterval(172_800))
        return (service, rag, fts, tok)
    }

    private func setUpdatedAt(_ service: LookupService, conceptId: Int64, _ date: Date) async throws {
        try await service.database.writer.write { db in
            try db.execute(sql: "UPDATE concept SET updatedAt = ? WHERE id = ?", arguments: [date, conceptId])
        }
    }

    private func latestRevisionId(_ service: LookupService, conceptId: Int64) async throws -> Int64 {
        try await service.database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM definitionRevision WHERE conceptId = ?", arguments: [conceptId])!
        }
    }

    /// 조회 기록을 지정 시각으로 직접 넣는다(recordLookup은 Date.now라 정렬 검증에 못 쓴다).
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

    @Test func counts는_저장_상태를_정확히_집계한다() async throws {
        let service = try makeService()
        let aiOnly = try await service.saveConcept(
            preferredTerm: "RAG", aliases: [], field: "AI",
            oneLine: "검색해 답을 만든다", easyExplanation: "찾아서 붙인다.",
            author: "ai", provider: "ollama:test"
        )
        let edited = try await service.saveConcept(
            preferredTerm: "FTS5", aliases: [], field: "DB",
            oneLine: "전문 검색", easyExplanation: "색인 검색.",
            author: "ai", provider: "ollama:test"
        )
        try await service.saveUserRevision(conceptId: edited, oneLine: "고친 한 줄", easyExplanation: "내가 고친 설명")
        try await service.saveConcept(
            preferredTerm: "토큰", aliases: [], field: nil,
            oneLine: "텍스트 조각", easyExplanation: "잘게 쪼갠 단위.",
            author: "user", provider: nil
        )
        try await service.setFavorite(conceptId: aiOnly, true)
        try await service.recordLookup("RAG", conceptId: aiOnly, status: .hit)
        try await service.recordLookup("없는 질문", conceptId: nil, status: .miss)

        let counts = try await service.libraryCounts()
        // 최신 개정본 기준: RAG=ai, FTS5=user(수정됨), 토큰=user.
        // recentLookups는 조회 기록이 있는 개념 수: hit 1건(RAG)만 해당, 개념 없는 miss는 제외.
        #expect(counts == LibraryCounts(all: 3, favorites: 1, aiGenerated: 1, userEdited: 2, recentLookups: 1))
    }

    private func insertSource(
        _ service: LookupService, revisionId: Int64, title: String,
        url: String? = nil, excerpt: String? = nil, retrievedAt: Date
    ) async throws {
        try await service.database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO sourceRef (revisionId, title, url, excerpt, retrievedAt) VALUES (?, ?, ?, ?, ?)",
                arguments: [revisionId, title, url, excerpt, retrievedAt]
            )
        }
    }
    @Test func listLibrary는_부분일치로_찾고_중복을_제거한다() async throws {
        let (service, rag, fts, tok) = try await seedLibrary()

        // 표제어 부분일치, 대소문자 무시
        #expect(try await service.listLibrary(search: "TOK").map(\.id) == [tok])
        #expect(try await service.listLibrary(search: "oken").map(\.id) == [tok])
        // 별칭 부분일치
        #expect(try await service.listLibrary(search: "full-text").map(\.id) == [fts])
        #expect(try await service.listLibrary(search: "증강").map(\.id) == [rag])
        // 한 줄 요약 부분일치
        #expect(try await service.listLibrary(search: "전문 검색").map(\.id) == [fts])
        // 표제어+별칭+요약에 걸쳐 매치돼도 개념별로 하나만 (최신수정순 유지)
        #expect(try await service.listLibrary(search: "검색").map(\.id) == [fts, rag])
        // 일치 없음
        #expect(try await service.listLibrary(search: "전혀없는검색어").isEmpty)
    }

    @Test func entryDetail은_최신개정본과_출처와_히스토리를_돌려준다() async throws {
        let (service, rag, _, _) = try await seedLibrary()

        // 구 개정본(ai)에 출처 2개
        let rev1 = try await latestRevisionId(service, conceptId: rag)
        try await insertSource(service, revisionId: rev1, title: "오래된 블로그", retrievedAt: base)
        try await insertSource(
            service, revisionId: rev1, title: "튜토리얼",
            url: "https://example.com/tut", excerpt: "RAG 입문",
            retrievedAt: base.addingTimeInterval(3_600)
        )
        // 사용자 개정본(최신) + 출처 2개
        try await service.saveUserRevision(conceptId: rag, oneLine: "외부 지식을 찾아 답을 만든다", easyExplanation: "검색해서 붙여 답한다.")
        let rev2 = try await latestRevisionId(service, conceptId: rag)
        #expect(rev2 > rev1)
        try await insertSource(
            service, revisionId: rev2, title: "공식 문서",
            url: "https://example.com/docs", excerpt: "Retrieval-Augmented",
            retrievedAt: base.addingTimeInterval(7_200)
        )
        try await insertSource(service, revisionId: rev2, title: "논문", retrievedAt: base.addingTimeInterval(10_800))
        // 히스토리 3건 (시각 고정)
        try await service.database.writer.write { db in
            for i in 0..<3 {
                try db.execute(
                    sql: "INSERT INTO lookupRecord (query, conceptId, status, lookedUpAt) VALUES (?, ?, 'hit', ?)",
                    arguments: ["rag 질문 \(i)", rag, base.addingTimeInterval(TimeInterval(60 * (i + 1)))]
                )
            }
        }

        let detail = try await service.entryDetail(conceptId: rag)
        let unwrapped = try #require(detail)
        #expect(unwrapped.entry.conceptId == rag)
        #expect(unwrapped.entry.preferredTerm == "RAG")
        #expect(unwrapped.entry.isFavorite == false)
        #expect(unwrapped.entry.revisionId == rev2)
        #expect(unwrapped.entry.author == "user")
        #expect(unwrapped.entry.oneLine == "외부 지식을 찾아 답을 만든다")
        #expect(unwrapped.entry.easyExplanation == "검색해서 붙여 답한다.")
        // 출처는 최신 개정본 것만, retrievedAt DESC
        #expect(unwrapped.sources.map(\.title) == ["논문", "공식 문서"])
        #expect(unwrapped.sources[0].url == nil)
        #expect(unwrapped.sources[1].url == "https://example.com/docs")
        // 히스토리는 최신순
        #expect(unwrapped.history.map(\.query) == ["rag 질문 2", "rag 질문 1", "rag 질문 0"])

        // 없는 개념은 nil
        #expect(try await service.entryDetail(conceptId: 999_999) == nil)
    }
    @Test func entryDetail은_히스토리를_최대_100건만_돌려준다() async throws {
        let (service, rag, _, _) = try await seedLibrary()
        try await service.database.writer.write { db in
            for i in 0..<105 {
                try db.execute(
                    sql: "INSERT INTO lookupRecord (query, conceptId, status, lookedUpAt) VALUES (?, ?, 'miss', ?)",
                    arguments: ["질문 \(i)", rag, base.addingTimeInterval(TimeInterval(i))]
                )
            }
        }
        let detail = try await service.entryDetail(conceptId: rag)
        let unwrapped = try #require(detail)
        #expect(unwrapped.history.count == 100)
        #expect(unwrapped.history.first?.query == "질문 104")
        #expect(unwrapped.history.last?.query == "질문 5")
    }

    @Test func setFavorite은_반영되고_수정시각을_갱신한다() async throws {
        let (service, rag, _, _) = try await seedLibrary()

        try await service.setFavorite(conceptId: rag, true)
        let detail = try await service.entryDetail(conceptId: rag)
        #expect(try #require(detail).entry.isFavorite == true)
        #expect(try await service.libraryCounts().favorites == 1)
        // updatedAt 갱신 → RAG가 목록 선두로
        let list = try await service.listLibrary()
        #expect(list.first?.id == rag)

        try await service.setFavorite(conceptId: rag, false)
        #expect(try #require(try await service.entryDetail(conceptId: rag)).entry.isFavorite == false)
        #expect(try await service.libraryCounts().favorites == 0)
    }

    @Test func saveUserRevision은_user_개정본을_추가하고_최신으로_보인다() async throws {
        let (service, rag, _, _) = try await seedLibrary()
        let revBefore = try await latestRevisionId(service, conceptId: rag)

        try await service.saveUserRevision(conceptId: rag, oneLine: "내가 고친 한 줄", easyExplanation: "내가 고친 설명")

        let detail = try await service.entryDetail(conceptId: rag)
        let unwrapped = try #require(detail)
        #expect(unwrapped.entry.author == "user")
        #expect(unwrapped.entry.oneLine == "내가 고친 한 줄")
        #expect(unwrapped.entry.revisionId! > revBefore)
        // 기존 개정본 보존 (덮어쓰기 아님): ai 1 + user 1
        let revCount = try await service.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM definitionRevision WHERE conceptId = ?", arguments: [rag])
        }
        #expect(revCount == 2)
        // updatedAt 갱신 → 목록 선두
        let list = try await service.listLibrary()
        #expect(list.first?.id == rag)
    }

    @Test func deleteConcept은_개념과_종속데이터를_지운다() async throws {
        let (service, rag, fts, tok) = try await seedLibrary()
        let rev = try await latestRevisionId(service, conceptId: rag)
        try await insertSource(service, revisionId: rev, title: "출처", retrievedAt: base)
        try await service.recordLookup("RAG", conceptId: rag, status: .hit)

        try await service.deleteConcept(conceptId: rag)

        #expect(try await service.entryDetail(conceptId: rag) == nil)
        #expect(try await service.listLibrary(search: "RAG").isEmpty)
        #expect(try await service.listLibrary().map(\.id) == [fts, tok])
        #expect(try await service.libraryCounts().all == 2)

        // cascade: 개정본·출처·별칭 삭제, 조회 기록 행은 남고 conceptId만 NULL
        let remain = try await service.database.writer.read { db in
            (
                revisions: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM definitionRevision WHERE conceptId = ?", arguments: [rag]) ?? -1,
                sources: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sourceRef WHERE revisionId = ?", arguments: [rev]) ?? -1,
                aliases: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM alias WHERE conceptId = ?", arguments: [rag]) ?? -1,
                orphanLookups: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lookupRecord WHERE conceptId IS NULL AND query = 'RAG'") ?? -1
            )
        }
        #expect(remain.revisions == 0)
        #expect(remain.sources == 0)
        #expect(remain.aliases == 0)
        #expect(remain.orphanLookups == 1)

        // 없는 개념 삭제도 오류 없이 통과
        try await service.deleteConcept(conceptId: 12345)
    }

    // MARK: - 카테고리 필터

    @Test func listLibrary는_카테고리별로_걸러서_돌려준다() async throws {
        let (service, rag, fts, tok) = try await seedLibrary()

        // all: updatedAt DESC(시드 고정: fts > tok > rag)
        #expect(try await service.listLibrary(filter: .all).map(\.id) == [fts, tok, rag])
        // aiGenerated: 최신 개정본 author == ai. fts는 user 개정본이 최신이라 제외.
        #expect(try await service.listLibrary(filter: .aiGenerated).map(\.id) == [rag])
        // userEdited: 최신 개정본 author == user
        #expect(try await service.listLibrary(filter: .userEdited).map(\.id) == [fts, tok])
        // favorites / recent: 조건에 해당하는 개념이 아직 없다
        #expect(try await service.listLibrary(filter: .favorites).isEmpty)
        #expect(try await service.listLibrary(filter: .recent).isEmpty)

        try await service.setFavorite(conceptId: tok, true)
        #expect(try await service.listLibrary(filter: .favorites).map(\.id) == [tok])
        try await service.recordLookup("토큰 질문", conceptId: tok, status: .hit)
        #expect(try await service.listLibrary(filter: .recent).map(\.id) == [tok])
    }

    @Test func listLibrary_recent는_최신조회순이고_조회당_한번만_나온다() async throws {
        let (service, rag, fts, tok) = try await seedLibrary()

        // tok: 같은 개념 두 번(과거) / fts: 중간 / rag: 가장 최근
        try await insertLookup(service, conceptId: tok, query: "토큰 오래된 질문", at: base.addingTimeInterval(100))
        try await insertLookup(service, conceptId: fts, query: "FTS 질문", at: base.addingTimeInterval(150))
        try await insertLookup(service, conceptId: tok, query: "토큰 두 번째 질문", at: base.addingTimeInterval(200))
        try await insertLookup(service, conceptId: rag, query: "RAG 질문", at: base.addingTimeInterval(300))

        // 최신 lookedUpAt DESC: rag(300) > tok(200) > fts(150). tok은 두 번 조회돼도 한 번만.
        #expect(try await service.listLibrary(filter: .recent).map(\.id) == [rag, tok, fts])
    }

    @Test func listLibrary_recent는_조회시각이_같으면_id가_큰_것부터_돌려준다() async throws {
        let (service, rag, fts, tok) = try await seedLibrary()
        let sameTime = base.addingTimeInterval(500)

        for (conceptId, query) in [(rag, "RAG"), (fts, "FTS5"), (tok, "tok")] {
            try await insertLookup(service, conceptId: conceptId, query: query, at: sameTime)
        }

        // 조회 시각 동률이면 id DESC: tok(3) > fts(2) > rag(1)
        #expect(try await service.listLibrary(filter: .recent).map(\.id) == [tok, fts, rag])
    }

    @Test func recent와_recentLookups는_삭제된_개념과_개념없는_기록을_세지_않는다() async throws {
        let (service, rag, _, _) = try await seedLibrary()

        try await service.recordLookup("rag 질문", conceptId: rag, status: .hit)
        try await service.recordLookup("개념 없는 질문", conceptId: nil, status: .miss)
        #expect(try await service.listLibrary(filter: .recent).map(\.id) == [rag])
        #expect(try await service.libraryCounts().recentLookups == 1)

        // 개념 삭제 → 기록 행은 남지만(conceptId NULL) recent에서는 사라진다.
        try await service.deleteConcept(conceptId: rag)
        #expect(try await service.listLibrary(filter: .recent).isEmpty)
        #expect(try await service.libraryCounts().recentLookups == 0)
    }

    @Test func listLibrary는_검색과_카테고리를_AND로_결합한다() async throws {
        let (service, rag, fts, _) = try await seedLibrary()

        // "검색"은 rag(별칭)와 fts(최신 요약)에 모두 걸린다.
        #expect(try await service.listLibrary(search: "검색").map(\.id) == [fts, rag])
        #expect(try await service.listLibrary(search: "검색", filter: .aiGenerated).map(\.id) == [rag])
        #expect(try await service.listLibrary(search: "검색", filter: .userEdited).map(\.id) == [fts])
        #expect(try await service.listLibrary(search: "검색", filter: .favorites).isEmpty)

        // 와일드카드는 문자 그대로 취급: "%", "R%"는 어떤 표제어도 매치하지 않는다.
        try await service.setFavorite(conceptId: rag, true)
        #expect(try await service.listLibrary(search: "%", filter: .all).isEmpty)
        #expect(try await service.listLibrary(search: "R%", filter: .favorites).isEmpty)
        #expect(try await service.listLibrary(search: "RAG", filter: .favorites).map(\.id) == [rag])
    }

    @Test func listLibrary의_limit은_필터_적용_후에_적용된다() async throws {
        let (service, rag, fts, tok) = try await seedLibrary()

        // 전체 목록 선두(fts)는 user 개정본이라, limit을 먼저 자르면 ai는 하나도 남지 않는다.
        #expect(try await service.listLibrary(filter: .aiGenerated, limit: 1).map(\.id) == [rag])
        #expect(try await service.listLibrary(filter: .userEdited, limit: 1).map(\.id) == [fts])
        #expect(try await service.listLibrary(filter: .userEdited).map(\.id) == [fts, tok])

        try await insertLookup(service, conceptId: tok, query: "토큰 질문", at: base)
        try await insertLookup(service, conceptId: rag, query: "RAG 질문", at: base.addingTimeInterval(60))
        #expect(try await service.listLibrary(filter: .recent).map(\.id) == [rag, tok])
        #expect(try await service.listLibrary(filter: .recent, limit: 1).map(\.id) == [rag])
    }

    @Test func recentLookups는_조회기록이_있는_서로_다른_개념_수다() async throws {
        let (service, rag, fts, _) = try await seedLibrary()

        try await service.recordLookup("첫", conceptId: rag, status: .hit)
        try await service.recordLookup("둘", conceptId: rag, status: .hit) // 같은 개념 재조회
        try await service.recordLookup("셋", conceptId: fts, status: .miss)
        try await service.recordLookup("개념 없는 질문", conceptId: nil, status: .miss)

        let counts = try await service.libraryCounts()
        #expect(counts.recentLookups == 2)
        #expect(try await service.listLibrary(filter: .recent).count == 2)
    }
}
