import SwiftUI
import LexiCore

/// 항목 상세 (목업 #6). 헤더(표제어·즐겨찾기·칩) + 설명/출처/히스토리 탭, 툴바 삭제.
struct EntryDetailView: View {
    let payload: LibraryViewModel.DetailPayload
    let viewModel: LibraryViewModel

    private enum Tab: Hashable {
        case explanation
        case sources
        case history
    }

    @State private var tab: Tab = .explanation
    @State private var isShowingEditSheet = false
    @State private var isShowingDeleteConfirmation = false

    private static let dateFormatter = Date.FormatStyle(date: .abbreviated, time: .shortened)

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding()
            Divider()
            Picker("보기", selection: $tab) {
                Text("설명").tag(Tab.explanation)
                Text("출처").tag(Tab.sources)
                Text("히스토리").tag(Tab.history)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            switch tab {
            case .explanation: explanationTab
            case .sources: sourcesTab
            case .history: historyTab
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    isShowingDeleteConfirmation = true
                } label: {
                    Label("삭제", systemImage: "trash")
                }
                .help("이 항목을 삭제해요")
            }
        }
        .sheet(isPresented: $isShowingEditSheet) {
            RevisionEditSheet(entry: payload.entry) { oneLine, easy in
                await viewModel.saveRevision(conceptId: payload.entry.conceptId, oneLine: oneLine, easy: easy)
            }
        }
        .confirmationDialog(
            "“\(payload.entry.preferredTerm)”을(를) 삭제할까요?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                Task { await viewModel.delete(conceptId: payload.entry.conceptId) }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("항목과 함께 저장된 수정·출처·기록이 사라져요. 되돌릴 수 없어요.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(payload.entry.preferredTerm)
                .font(.largeTitle.weight(.bold))
                .lineLimit(2)
            Spacer()
            Button {
                Task {
                    await viewModel.setFavorite(
                        conceptId: payload.entry.conceptId,
                        to: !payload.entry.isFavorite
                    )
                }
            } label: {
                Image(systemName: payload.entry.isFavorite ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(payload.entry.isFavorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(payload.entry.isFavorite ? "즐겨찾기 해제" : "즐겨찾기 추가")

            if let field = payload.entry.field, !field.isEmpty {
                chip(field, color: .secondary)
            }
            if let author = payload.entry.author {
                switch author {
                case "ai": chip("AI", color: .blue)
                case "user": chip("내가 수정함", color: .green)
                default: chip(author, color: .secondary)
                }
            }
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var explanationTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let hasExplanation = !(payload.entry.oneLine ?? "").isEmpty
                    || !(payload.entry.easyExplanation ?? "").isEmpty
                if hasExplanation {
                    if let oneLine = payload.entry.oneLine, !oneLine.isEmpty {
                        Text(oneLine)
                            .font(.title3.weight(.semibold))
                    }
                    if let easy = payload.entry.easyExplanation, !easy.isEmpty {
                        Text(easy)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.primary.opacity(0.05))
                            )
                    }
                } else {
                    ContentUnavailableView(
                        "아직 설명이 없어요",
                        systemImage: "text.bubble",
                        description: Text("아래 수정 버튼으로 한 줄 정의와 쉬운 설명을 써 보세요.")
                    )
                }
                HStack {
                    Spacer()
                    Button("수정") {
                        isShowingEditSheet = true
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var sourcesTab: some View {
        if payload.sources.isEmpty {
            ContentUnavailableView(
                "출처 없음 — AI 초안",
                systemImage: "doc.text.magnifyingglass",
                description: Text("웹 출처 확인 없이 작성된 AI 초안이에요.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(payload.sources) { source in
                        sourceRow(source)
                    }
                }
                .padding()
            }
        }
    }

    private func sourceRow(_ source: SourceItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let urlString = source.url, let url = URL(string: urlString) {
                Link(destination: url) {
                    Text(source.title)
                        .fontWeight(.medium)
                }
            } else {
                Text(source.title)
                    .fontWeight(.medium)
            }
            if let excerpt = source.excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Text(source.retrievedAt, format: Self.dateFormatter)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    @ViewBuilder
    private var historyTab: some View {
        if payload.history.isEmpty {
            ContentUnavailableView(
                "조회 기록이 없어요",
                systemImage: "clock.arrow.circlepath"
            )
        } else {
            List {
                ForEach(payload.history) { item in
                    HStack {
                        Text(item.query)
                        Spacer()
                        Text(item.lookedUpAt, format: Self.dateFormatter)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

/// 한 줄 정의 + 쉬운 설명을 고치는 시트. 저장은 saveRevision으로 이어진다.
private struct RevisionEditSheet: View {
    let entry: DictionaryEntry
    let onSave: (String, String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var oneLine: String
    @State private var easyExplanation: String
    @State private var isSaving = false

    init(entry: DictionaryEntry, onSave: @escaping (String, String) async -> Void) {
        self.entry = entry
        self.onSave = onSave
        _oneLine = State(initialValue: entry.oneLine ?? "")
        _easyExplanation = State(initialValue: entry.easyExplanation ?? "")
    }

    private var canSave: Bool {
        let hasContent = !oneLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !easyExplanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasContent && !isSaving
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("\"\(entry.preferredTerm)\" 수정") {
                    TextField("한 줄 정의", text: $oneLine)
                    TextField("쉬운 설명", text: $easyExplanation, axis: .vertical)
                        .lineLimit(5...10)
                }
            }
            .formStyle(.grouped)
            .padding()

            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                Button("저장") {
                    isSaving = true
                    Task {
                        await onSave(oneLine, easyExplanation)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 460)
        .navigationTitle("설명 수정")
    }
}
