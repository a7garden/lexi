import SwiftUI
import LexiCore

/// 전체 사전 화면 (목업 #6). 사이드바에 라이브러리 섹션 카운트와 항목 목록,
/// 오른쪽에 선택한 항목의 상세를 보여준다.
struct LibraryView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @State private var isShowingNewEntrySheet = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailColumn
        }
        .navigationTitle("Lexi")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingNewEntrySheet = true
                } label: {
                    Label("새 항목", systemImage: "plus")
                }
                .help("직접 입력해서 항목을 추가해요")
            }
        }
        .searchable(
            text: Binding(
                get: { viewModel.searchText },
                set: { viewModel.setSearch(text: $0) }
            ),
            placement: .sidebar,
            prompt: "표제어 검색"
        )
        .sheet(isPresented: $isShowingNewEntrySheet) {
            NewEntrySheet { term, oneLine, easy in
                await viewModel.createEntry(term: term, oneLine: oneLine, easy: easy)
            }
        }
        .alert(
            "라이브러리 오류",
            isPresented: Binding(
                get: { viewModel.loadError != nil },
                set: { if !$0 { viewModel.dismissError() } }
            ),
            presenting: viewModel.loadError
        ) { _ in
            Button("확인", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { viewModel.selectedConceptId },
            set: { viewModel.select(conceptId: $0) }
        )) {
            Section("라이브러리") {
                Label("모든 항목", systemImage: "books.vertical")
                    .badge(sectionCount(\.all))
                Label("최근 조회", systemImage: "clock")
                    .badge(sectionCount(\.recentLookups))
                Label("즐겨찾기", systemImage: "star")
                    .badge(sectionCount(\.favorites))
                Label("AI 생성", systemImage: "sparkles")
                    .badge(sectionCount(\.aiGenerated))
                Label("내가 수정한 항목", systemImage: "pencil.line")
                    .badge(sectionCount(\.userEdited))
            }
            Section("항목") {
                if viewModel.items.isEmpty {
                    Text(viewModel.searchText.isEmpty ? "아직 항목이 없어요" : "검색 결과가 없어요")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.items) { item in
                        itemRow(item)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 250)
        .overlay {
            if !viewModel.isLoaded, viewModel.loadError == nil {
                ProgressView("라이브러리 불러오는 중…")
            }
        }
    }

    private func sectionCount(_ keyPath: KeyPath<LibraryCounts, Int>) -> Text {
        Text(viewModel.counts.map { "\($0[keyPath: keyPath])" } ?? "–")
    }

    private func itemRow(_ item: LexiCore.LibraryItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preferredTerm)
                    .fontWeight(.medium)
                if let oneLine = item.oneLine, !oneLine.isEmpty {
                    Text(oneLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if item.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }
        }
        .tag(item.conceptId)
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let payload = viewModel.detail {
            EntryDetailView(payload: payload, viewModel: viewModel)
        } else {
            ContentUnavailableView(
                "항목을 선택하세요",
                systemImage: "book.closed",
                description: Text("왼쪽 목록에서 항목을 고르거나, 앱 밖에서 모르는 단어를 조회해 보세요.")
            )
        }
    }
}

/// 직접 입력으로 새 항목을 추가하는 시트. 저장은 saveConcept(author: "user")로 이어진다.
private struct NewEntrySheet: View {
    let onSave: (String, String, String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var term = ""
    @State private var oneLine = ""
    @State private var easyExplanation = ""
    @State private var isSaving = false

    private var canSave: Bool {
        !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("표제어", text: $term)
                TextField("한 줄 정의", text: $oneLine)
                TextField("쉬운 설명", text: $easyExplanation, axis: .vertical)
                    .lineLimit(3...6)
            }
            .formStyle(.grouped)
            .padding()

            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                Button("저장") {
                    isSaving = true
                    Task {
                        await onSave(term, oneLine, easyExplanation)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 420)
        .navigationTitle("새 항목")
    }
}
