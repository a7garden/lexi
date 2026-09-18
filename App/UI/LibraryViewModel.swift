import SwiftUI
import LexiCore

/// 사전의 검색·분류·선택·편집 상태. 비동기 요청이 뒤늦게 최신 목록을 덮어쓰지 않도록 관리한다.
@MainActor
final class LibraryViewModel: ObservableObject {
    /// entryDetail 튜플을 화면 친화적 값으로 감싼 상세 페이로드.
    struct DetailPayload: Equatable {
        var entry: DictionaryEntry
        var sources: [SourceItem]
        var history: [HistoryItem]
    }

    @Published private(set) var items: [LexiCore.LibraryItem] = []
    @Published private(set) var counts: LibraryCounts?
    @Published private(set) var selectedConceptId: Int64?
    @Published private(set) var detail: DetailPayload?
    @Published private(set) var searchText = ""
    @Published private(set) var filter: LibraryFilter = .all
    @Published private(set) var semanticMatches: [SemanticLibraryMatch] = []
    @Published private(set) var isSemanticSearching = false
    @Published private(set) var semanticMessage: String?
    @Published private(set) var loadError: String?
    @Published private(set) var isLoaded = false

    private var database: AppDatabase?
    private var service: LookupService?
    private var semanticSearch: SemanticLibrarySearch?
    private var searchTask: Task<Void, Never>?
    private var semanticTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var semanticGeneration = 0

    init() {
        bootstrap()
    }

    init(database: AppDatabase) {
        configure(database: database)
    }

    init(database: AppDatabase, embeddingProvider: any TextEmbeddingProvider) {
        configure(database: database, embeddingProvider: embeddingProvider)
    }

    private func configure(
        database: AppDatabase,
        embeddingProvider: any TextEmbeddingProvider = MLXTextEmbeddingProvider()
    ) {
        self.database = database
        let service = LookupService(database: database)
        self.service = service
        self.semanticSearch = SemanticLibrarySearch(service: service, provider: embeddingProvider)
    }

    /// 지연 초기화: DB 열기 + 마이그레이션. 실패는 loadError로 화면에 표시한다.
    private func bootstrap() {
        Task {
            do {
                let database = try AppDatabase.makeDefault()
                try database.migrate()
                self.configure(database: database)
                await refresh()
            } catch {
                loadError = String(localized: "라이브러리 데이터베이스를 열 수 없어요: \(error.localizedDescription)")
            }
        }
    }

    /// 목록 + 카운트를 다시 읽는다.
    func refresh() async {
        guard let service else { return }
        resetSemanticResults()
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            async let itemList = service.listLibrary(search: searchText, filter: filter, limit: 500)
            async let countSnapshot = service.libraryCounts()
            let (newItems, newCounts) = try await (itemList, countSnapshot)
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            items = newItems
            counts = newCounts
            if let selectedConceptId, !items.contains(where: { $0.conceptId == selectedConceptId }) {
                select(conceptId: nil)
            }
            loadError = nil
            isLoaded = true
        } catch {
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            loadError = String(localized: "라이브러리를 불러오지 못했어요: \(error.localizedDescription)")
        }
    }

    func setFilter(_ filter: LibraryFilter) {
        self.filter = filter
        resetSemanticResults()
        searchTask?.cancel()
        searchTask = Task { await refresh() }
    }

    func reveal(conceptID: Int64) async {
        searchTask?.cancel()
        filter = .all
        searchText = ""
        resetSemanticResults()
        await refresh()
        select(conceptId: conceptID)
    }

    /// 검색어 설정. 300ms 디바운스 후 목록을 갱신한다.
    func setSearch(text: String) {
        searchText = text
        resetSemanticResults()
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    /// 현재 일반 검색 결과와 겹치지 않는 의미상 유사한 개념을 별도 구역에 불러온다.
    /// 모델 파일은 이 명시적 동작에서만 처음 다운로드될 수 있다.
    func findSimilar() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let service, let semanticSearch else { return }

        searchTask?.cancel()
        searchTask = nil
        semanticTask?.cancel()
        semanticGeneration += 1
        let generation = semanticGeneration
        let currentFilter = filter
        semanticMatches = []
        semanticMessage = nil
        isSemanticSearching = true

        semanticTask = Task {
            do {
                // 300ms 일반 검색 디바운스가 끝나기 전에 눌러도 정확한 중복 제외 집합을 사용한다.
                let lexicalItems = try await service.listLibrary(
                    search: query,
                    filter: currentFilter,
                    limit: 500
                )
                guard generation == semanticGeneration,
                      query == searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                      currentFilter == filter,
                      !Task.isCancelled
                else { return }
                items = lexicalItems

                let matches = try await semanticSearch.matches(
                    query: query,
                    filter: currentFilter,
                    excludingConceptIDs: Set(lexicalItems.map(\.conceptId))
                )
                guard generation == semanticGeneration,
                      query == searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                      currentFilter == filter,
                      !Task.isCancelled
                else { return }
                semanticMatches = matches
                semanticMessage = matches.isEmpty
                    ? String(localized: "의미가 충분히 비슷한 저장된 개념을 찾지 못했어요.")
                    : nil
                isSemanticSearching = false
            } catch is CancellationError {
                guard generation == semanticGeneration else { return }
                isSemanticSearching = false
            } catch {
                guard generation == semanticGeneration, !Task.isCancelled else { return }
                semanticMatches = []
                semanticMessage = error.localizedDescription
                isSemanticSearching = false
            }
        }
    }

    private func resetSemanticResults() {
        semanticTask?.cancel()
        semanticTask = nil
        semanticGeneration += 1
        semanticMatches = []
        semanticMessage = nil
        isSemanticSearching = false
    }

    /// 항목 선택 → 상세 로드. nil이면 상세를 닫는다.
    func select(conceptId: Int64?) {
        selectedConceptId = conceptId
        detail = nil
        detailTask?.cancel()
        guard let conceptId else {
            detail = nil
            return
        }
        detailTask = Task {
            await loadDetail(conceptId: conceptId)
        }
    }

    private func loadDetail(conceptId: Int64) async {
        guard let service else { return }
        do {
            let payload = try await service.entryDetail(conceptId: conceptId)
            guard selectedConceptId == conceptId, !Task.isCancelled else { return }
            detail = payload.map { DetailPayload(entry: $0.entry, sources: $0.sources, history: $0.history) }
            loadError = nil
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            loadError = String(localized: "상세 정보를 불러오지 못했어요: \(error.localizedDescription)")
        }
    }

    /// 목록 행에서 즐겨찾기 토글.
    func toggleFavorite(item: LexiCore.LibraryItem) {
        Task { await setFavorite(conceptId: item.conceptId, to: !item.isFavorite) }
    }

    /// 즐겨찾기 변경 — 화면에 먼저 반영(낙관적)하고, 실패하면 되돌린다.
    func setFavorite(conceptId: Int64, to isFavorite: Bool) async {
        applyFavorite(conceptId: conceptId, isFavorite: isFavorite)
        guard let service else { return }
        do {
            try await service.setFavorite(conceptId: conceptId, isFavorite)
            await refresh()
        } catch {
            applyFavorite(conceptId: conceptId, isFavorite: !isFavorite)
            loadError = String(localized: "즐겨찾기를 변경하지 못했어요: \(error.localizedDescription)")
        }
    }

    private func applyFavorite(conceptId: Int64, isFavorite: Bool) {
        var countChanged = false
        if let index = items.firstIndex(where: { $0.conceptId == conceptId }),
           items[index].isFavorite != isFavorite {
            items[index].isFavorite = isFavorite
            countChanged = true
        }
        if detail?.entry.conceptId == conceptId,
           detail?.entry.isFavorite != isFavorite {
            detail?.entry.isFavorite = isFavorite
            countChanged = true
        }
        if countChanged {
            counts?.favorites += isFavorite ? 1 : -1
        }
    }

    /// 항목 삭제 — 상세를 닫고 목록·카운트를 갱신한다.
    func delete(conceptId: Int64) async {
        guard let service else { return }
        do {
            try await service.deleteConcept(conceptId: conceptId)
            if selectedConceptId == conceptId {
                select(conceptId: nil)
            }
            await refresh()
        } catch {
            loadError = String(localized: "항목을 삭제하지 못했어요: \(error.localizedDescription)")
        }
    }

    /// 사용자 수정 저장 후 상세 + 리스트를 갱신한다.
    func saveRevision(conceptId: Int64, oneLine: String, easy: String) async -> String? {
        guard let service else { return String(localized: "사전을 준비하는 중이에요. 잠시 후 다시 시도해 주세요.") }
        do {
            try await service.saveUserRevision(conceptId: conceptId, oneLine: oneLine, easyExplanation: easy)
            await refresh()
            detailTask?.cancel()
            detailTask = Task { await loadDetail(conceptId: conceptId) }
            return nil
        } catch {
            return String(localized: "수정을 저장하지 못했어요: \(error.localizedDescription)")
        }
    }

    /// 직접 입력으로 새 항목을 만든다. 작성자는 "user".
    func createEntry(term: String, oneLine: String, easy: String) async -> String? {
        guard let service else { return String(localized: "사전을 준비하는 중이에요. 잠시 후 다시 시도해 주세요.") }
        do {
            let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return String(localized: "개념 이름을 입력해 주세요.") }
            let conceptID = try await service.saveConcept(
                preferredTerm: term,
                aliases: [],
                field: nil,
                oneLine: oneLine.trimmingCharacters(in: .whitespacesAndNewlines),
                easyExplanation: easy.trimmingCharacters(in: .whitespacesAndNewlines),
                author: "user",
                provider: nil
            )
            await reveal(conceptID: conceptID)
            return nil
        } catch {
            return String(localized: "새 항목을 추가하지 못했어요: \(error.localizedDescription)")
        }
    }

    func dismissError() {
        loadError = nil
    }
}
