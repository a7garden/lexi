import SwiftUI
import LexiCore

/// 라이브러리 화면 상태 (목업 #6). 하나의 AppDatabase/LookupService를 보유해 재오픈 중복을 막는다.
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
    @Published private(set) var loadError: String?
    @Published private(set) var isLoaded = false

    private var database: AppDatabase?
    private var service: LookupService?
    private var searchTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?

    init() {
        bootstrap()
    }

    /// 지연 초기화: DB 열기 + 마이그레이션. 실패는 loadError로 화면에 표시한다.
    private func bootstrap() {
        Task {
            do {
                let database = try AppDatabase.makeDefault()
                try database.migrate()
                self.database = database
                self.service = LookupService(database: database)
                await refresh()
            } catch {
                loadError = "라이브러리 데이터베이스를 열 수 없어요: \(error.localizedDescription)"
            }
        }
    }

    /// 목록 + 카운트를 다시 읽는다.
    func refresh() async {
        guard let service else { return }
        do {
            async let itemList = service.listLibrary(search: searchText, limit: 500)
            async let countSnapshot = service.libraryCounts()
            items = try await itemList
            counts = try await countSnapshot
            loadError = nil
            isLoaded = true
        } catch {
            loadError = "라이브러리를 불러오지 못했어요: \(error.localizedDescription)"
        }
    }

    /// 검색어 설정. 300ms 디바운스 후 목록을 갱신한다.
    func setSearch(text: String) {
        searchText = text
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    /// 항목 선택 → 상세 로드. nil이면 상세를 닫는다.
    func select(conceptId: Int64?) {
        selectedConceptId = conceptId
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
            loadError = "상세 정보를 불러오지 못했어요: \(error.localizedDescription)"
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
        } catch {
            applyFavorite(conceptId: conceptId, isFavorite: !isFavorite)
            loadError = "즐겨찾기를 변경하지 못했어요: \(error.localizedDescription)"
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
            loadError = "항목을 삭제하지 못했어요: \(error.localizedDescription)"
        }
    }

    /// 사용자 수정 저장 후 상세 + 리스트를 갱신한다.
    func saveRevision(conceptId: Int64, oneLine: String, easy: String) async {
        guard let service else { return }
        do {
            try await service.saveUserRevision(conceptId: conceptId, oneLine: oneLine, easyExplanation: easy)
            await refresh()
            detailTask?.cancel()
            detailTask = Task { await loadDetail(conceptId: conceptId) }
        } catch {
            loadError = "수정을 저장하지 못했어요: \(error.localizedDescription)"
        }
    }

    /// 직접 입력으로 새 항목을 만든다. 작성자는 "user".
    func createEntry(term: String, oneLine: String, easy: String) async {
        guard let service else { return }
        do {
            // 반환값은 사용하지 않음(@discardableResult Int64).
            _ = try await service.saveConcept(
                preferredTerm: term,
                aliases: [],
                field: nil,
                oneLine: oneLine.isEmpty ? "-" : oneLine,
                easyExplanation: easy.isEmpty ? "-" : easy,
                author: "user",
                provider: nil
            )
            await refresh()
        } catch {
            loadError = "새 항목을 추가하지 못했어요: \(error.localizedDescription)"
        }
    }

    func dismissError() {
        loadError = nil
    }
}
