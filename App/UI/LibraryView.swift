import AppKit
import SwiftUI
import LexiCore

extension LibraryFilter {
    var title: String {
        switch self {
        case .all: "모든 개념"
        case .recent: "최근 조회"
        case .favorites: "즐겨찾기"
        case .aiGenerated: "AI 초안"
        case .userEdited: "직접 작성"
        }
    }
    var icon: String {
        switch self {
        case .all: "books.vertical"
        case .recent: "clock"
        case .favorites: "star"
        case .aiGenerated: "sparkles"
        case .userEdited: "square.and.pencil"
        }
    }
    func count(in counts: LibraryCounts?) -> Int? {
        guard let counts else { return nil }
        switch self {
        case .all: return counts.all
        case .recent: return counts.recentLookups
        case .favorites: return counts.favorites
        case .aiGenerated: return counts.aiGenerated
        case .userEdited: return counts.userEdited
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var appDelegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = LibraryViewModel()
    @State private var isShowingNewEntrySheet = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 300, ideal: 350, max: 420)
        } detail: {
            detailColumn
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("Lexi")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SettingsLink { Label("설정", systemImage: "gearshape") }
                    .help("Lexi 설정")
                Button {
                    isShowingNewEntrySheet = true
                } label: { Label("개념 추가", systemImage: "plus") }
                .help("개념을 직접 작성하거나 AI로 조회해요 (⌘N)")
            }
        }
        .sheet(isPresented: $isShowingNewEntrySheet) {
            NewEntrySheet(onLookup: { appDelegate.startLookup($0) }) { term, oneLine, easy in
                await viewModel.createEntry(term: term, oneLine: oneLine, easy: easy)
            }
        }
        .alert("사전 오류", isPresented: Binding(
            get: { viewModel.loadError != nil && !isShowingNewEntrySheet },
            set: { if !$0 { viewModel.dismissError() } }
        )) {
            Button("확인", role: .cancel) { viewModel.dismissError() }
        } message: { Text(viewModel.loadError ?? "") }
        .task { handleRequest() }
        .onChange(of: appDelegate.libraryRequest?.id) { _, _ in handleRequest() }
        .onChange(of: viewModel.isLoaded) { _, _ in handleRequest() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await viewModel.refresh() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lexiLibraryChanged)) { _ in
            Task { await viewModel.refresh() }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "character.book.closed.fill")
                        .font(.title2).foregroundStyle(Color.accentColor)
                    Text("내 사전").font(.title3.bold())
                    Spacer()
                    Text("\(viewModel.counts?.all ?? 0)개의 개념")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("개념, 별칭, 설명 검색", text: Binding(
                        get: { viewModel.searchText }, set: { viewModel.setSearch(text: $0) }
                    ))
                    .textFieldStyle(.plain)
                    .accessibilityLabel("개념 검색")
                    if !viewModel.searchText.isEmpty {
                        Button { viewModel.setSearch(text: "") } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain).accessibilityLabel("검색 지우기")
                    }
                }
                .padding(10)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                if !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: 8) {
                        Button {
                            viewModel.findSimilar()
                        } label: {
                            Label(
                                viewModel.semanticMatches.isEmpty ? "의미로 찾기" : "의미 검색 다시 하기",
                                systemImage: "point.3.connected.trianglepath.dotted"
                            )
                        }
                        .controlSize(.small)
                        .disabled(viewModel.isSemanticSearching)
                        .help("처음 사용하면 다국어 임베딩 모델을 내려받습니다. 검색어와 사전 내용은 Mac 안에서 처리해요.")
                        Spacer()
                        Text("로컬 임베딩")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                VStack(spacing: 7) {
                    HStack(spacing: 7) {
                        filterButton(.all)
                        filterButton(.recent)
                        filterButton(.favorites)
                    }
                    HStack(spacing: 7) {
                        filterButton(.aiGenerated)
                        filterButton(.userEdited)
                    }
                }
            }.padding(16)
            Divider()
            HStack {
                Text(viewModel.filter.title).font(.caption.weight(.semibold))
                Spacer()
                Text("\(viewModel.items.count + viewModel.semanticMatches.count)개").font(.caption)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 6)
            conceptList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            SettingsLink {
                Label("우클릭·단축키 사용 방법", systemImage: "cursorarrow.click")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.link)
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func filterButton(_ filter: LibraryFilter) -> some View {
        let selected = viewModel.filter == filter
        return Button {
            appDelegate.lookupNotice = nil
            viewModel.setFilter(filter)
        } label: {
            HStack(spacing: 5) {
                Text(filter.title).lineLimit(1)
                Text(filter.count(in: viewModel.counts).map(String.init) ?? "–")
                    .monospacedDigit().opacity(0.65)
            }
            .font(.caption.weight(selected ? .semibold : .regular))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(filter.title), \(filter.count(in: viewModel.counts) ?? 0)개")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var conceptList: some View {
        if !viewModel.isLoaded, viewModel.loadError == nil {
            ProgressView("사전 불러오는 중…")
        } else if viewModel.items.isEmpty,
                  viewModel.semanticMatches.isEmpty,
                  viewModel.isSemanticSearching {
            VStack(spacing: 12) {
                ProgressView()
                Text("의미가 비슷한 개념을 찾는 중…")
                    .font(.headline)
                Text("처음 사용하면 다국어 임베딩 모델을 내려받아 시간이 더 걸릴 수 있어요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        } else if viewModel.items.isEmpty, viewModel.semanticMatches.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: viewModel.searchText.isEmpty ? viewModel.filter.icon : "magnifyingglass")
                    .font(.system(size: 28)).foregroundStyle(.tertiary)
                Text(emptyListTitle).font(.headline)
                Text(viewModel.semanticMessage ?? emptyListDescription)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if !viewModel.searchText.isEmpty {
                    Button("의미가 비슷한 개념 찾기", systemImage: "point.3.connected.trianglepath.dotted") {
                        viewModel.findSimilar()
                    }
                    Button("이 개념 AI로 조회") { appDelegate.startLookup(viewModel.searchText) }
                } else if viewModel.filter == .all || viewModel.filter == .userEdited {
                    Button("개념 추가") { isShowingNewEntrySheet = true }
                } else {
                    Button("모든 개념 보기") { viewModel.setFilter(.all) }
                }
            }
            .padding(24)
        } else {
            VStack(spacing: 0) {
                List(selection: Binding(
                    get: { viewModel.selectedConceptId },
                    set: {
                        appDelegate.lookupNotice = nil
                        viewModel.select(conceptId: $0)
                    }
                )) {
                    if viewModel.semanticMatches.isEmpty {
                        ForEach(viewModel.items) { item in itemRow(item) }
                    } else {
                        if !viewModel.items.isEmpty {
                            Section("텍스트 일치") {
                                ForEach(viewModel.items) { item in itemRow(item) }
                            }
                        }
                        Section {
                            ForEach(viewModel.semanticMatches) { match in
                                itemRow(match.item)
                            }
                        } header: {
                            Label("의미가 비슷한 개념", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                    }
                }.listStyle(.inset)
                if viewModel.isSemanticSearching {
                    ProgressView("의미가 비슷한 개념을 찾는 중…")
                        .controlSize(.small)
                        .padding(8)
                } else if let message = viewModel.semanticMessage {
                    Label(message, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                if viewModel.items.count == 500 {
                    Text("최근 500개를 표시 중이에요. 검색으로 범위를 좁혀 주세요.")
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                }
            }
        }
    }

    private var emptyListTitle: String {
        if !viewModel.searchText.isEmpty { return "검색 결과가 없어요" }
        switch viewModel.filter {
        case .favorites: return "즐겨찾기가 비어 있어요"
        case .userEdited: return "직접 작성한 개념이 없어요"
        case .recent: return "최근 조회한 개념이 없어요"
        case .aiGenerated: return "저장된 AI 초안이 없어요"
        case .all: return "첫 개념을 추가해 보세요"
        }
    }

    private var emptyListDescription: String {
        if !viewModel.searchText.isEmpty { return "다른 검색어로 찾아보거나 AI로 조회해 보세요." }
        switch viewModel.filter {
        case .favorites: return "자주 보는 개념의 별을 눌러\n여기에 모아 두세요."
        case .userEdited: return "직접 쓴 설명과 수정한 개념을\n한곳에서 볼 수 있어요."
        case .recent: return "단축키나 우클릭으로 조회한 개념이\n최근 순서로 표시됩니다."
        case .aiGenerated: return "AI로 조회해 저장한 개념이\n여기에 표시됩니다."
        case .all: return "궁금한 개념을 직접 작성하거나\nAI에게 설명을 요청해 보세요."
        }
    }

    private func itemRow(_ item: LexiCore.LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(item.preferredTerm).font(.body.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if item.isFavorite {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                }
            }
            Text(item.oneLine.flatMap { $0.isEmpty ? nil : $0 } ?? "설명을 추가해 보세요")
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Label(item.author == "ai" ? "AI 초안" : "직접 작성", systemImage: item.author == "ai" ? "sparkles" : "pencil")
                Spacer()
                Text(item.updatedAt, format: .dateTime.month().day())
            }.font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 9)
        .tag(item.conceptId)
        .contextMenu {
            Button("개념 열기") { viewModel.select(conceptId: item.conceptId) }
            Button(item.isFavorite ? "즐겨찾기 해제" : "즐겨찾기 추가", systemImage: item.isFavorite ? "star.slash" : "star") {
                viewModel.toggleFavorite(item: item)
            }
            Button("개념 이름 복사", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.preferredTerm, forType: .string)
            }
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let notice = appDelegate.lookupNotice {
            VStack(alignment: .leading, spacing: 12) {
                Label("선택한 텍스트를 확인해 주세요", systemImage: "text.cursor")
                    .font(.headline)
                Text(notice).foregroundStyle(.secondary)
                HStack {
                    SettingsLink { Text("단축키·권한 설정") }
                    Button("닫기") { appDelegate.lookupNotice = nil }
                }
            }.padding(24)
        } else if let payload = viewModel.detail {
            EntryDetailView(payload: payload, viewModel: viewModel)
                .id(payload.entry.conceptId)
        } else if viewModel.selectedConceptId != nil {
            ProgressView("개념 불러오는 중…")
        } else {
            ContentUnavailableView {
                Label("낯선 개념을 내 지식으로", systemImage: "character.book.closed")
            } description: {
                Text("목록에서 개념을 선택하거나 새로 추가해 보세요.\n설명과 출처를 한곳에 모아 다시 꺼내 볼 수 있어요.")
            } actions: {
                Button("개념 추가") { isShowingNewEntrySheet = true }
                    .buttonStyle(.borderedProminent)
                Button("클립보드로 조회") { appDelegate.searchClipboard() }
            }
        }
    }

    private func handleRequest() {
        guard viewModel.isLoaded, let request = appDelegate.libraryRequest else { return }
        appDelegate.libraryRequest = nil
        appDelegate.lookupNotice = nil
        if request.newEntry { isShowingNewEntrySheet = true }
        if let conceptID = request.conceptID { Task { await viewModel.reveal(conceptID: conceptID) } }
    }
}

private struct NewEntrySheet: View {
    let onLookup: (String) -> Void
    let onSave: (String, String, String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isTermFocused: Bool
    @State private var term = ""
    @State private var oneLine = ""
    @State private var easyExplanation = ""
    @State private var isSaving = false
    @State private var saveError: String?
    private var canSave: Bool { !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("개념 추가").font(.title2.bold())
                Text("직접 정리하거나 개념 이름만 입력하고 AI로 조회해 보세요.")
                    .foregroundStyle(.secondary)
            }.padding(24)
            Divider()
            Form {
                TextField("개념 이름", text: $term, prompt: Text("예: 기회비용"))
                    .focused($isTermFocused)
                TextField("한 줄 정의", text: $oneLine, prompt: Text("핵심 의미를 짧게 적어 주세요 (선택)"))
                TextField("쉬운 설명", text: $easyExplanation, axis: .vertical)
                    .lineLimit(5...8)
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red).font(.callout)
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Button("AI로 조회", systemImage: "sparkles") {
                    onLookup(term)
                    dismiss()
                }.disabled(!canSave)
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button("취소", role: .cancel) { dismiss() }.disabled(isSaving)
                Button("저장") {
                    isSaving = true
                    Task {
                        let error = await onSave(term, oneLine, easyExplanation)
                        isSaving = false
                        if let error { saveError = error } else { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction).disabled(!canSave)
            }.padding(20)
        }
        .frame(width: 540, height: 430)
        .interactiveDismissDisabled(isSaving)
        .onAppear { isTermFocused = true }
    }
}
