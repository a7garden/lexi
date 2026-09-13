import SwiftUI
import LexiCore

/// 즉시 보기 패널 본문 (목업 #3~5). 상태별 렌더링 + 한국어 라벨 고정.
/// 밝은 카드 + 부드러운 초록 포인트. 다크/라이트는 시맨틱 컬러로 대응.
struct PanelContentView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if showsScroll {
                ScrollView {
                    stateBody
                        .padding(16)
                }
            } else {
                stateBody
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 380, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.blue)
                .frame(width: 22, height: 22)
                .overlay(
                    Text("L")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(.white)
                )
            Text("Lexi")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if let favorite {
                Image(systemName: favorite ? "star.fill" : "star")
                    .font(.system(size: 13))
                    .foregroundStyle(favorite ? Color.yellow : Color.secondary)
            }
            Button {
                model.onClose?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// hit/result는 entry.isFavorite, 나머지 상태는 별 미표시.
    private var favorite: Bool? {
        switch model.state {
        case .hit(let entry), .result(let entry, _, _): entry.isFavorite
        default: nil
        }
    }

    // MARK: - State routing

    private var showsScroll: Bool {
        switch model.state {
        case .hit, .result: true
        case .researching, .empty, .failed: false
        }
    }

    @ViewBuilder
    private var stateBody: some View {
        switch model.state {
        case .hit(let entry):
            HitStateView(entry: entry, model: model)
        case .researching(let query):
            ResearchingStateView(query: query, model: model)
        case .result(let entry, let sources, let saved):
            ResultStateView(entry: entry, sources: sources, saved: saved, model: model)
        case .empty(let query):
            EmptyStateView(query: query, model: model)
        case .failed(_, let message):
            FailedStateView(message: message, model: model)
        }
    }
}

// MARK: - hit(DictionaryEntry)

private struct HitStateView: View {
    let entry: DictionaryEntry
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(entry.preferredTerm)
                .font(.system(size: 22, weight: .bold))
            HStack(spacing: 6) {
                if let field = entry.field, !field.isEmpty {
                    ChipView(text: field, tint: .blue)
                }
                ChipView(text: entry.author == "user" ? "내가 수정함" : "저장된 항목", tint: .green)
            }
            if let oneLine = entry.oneLine {
                Text(oneLine)
                    .font(.system(size: 14))
                    .lineSpacing(4)
            }
            if let easy = entry.easyExplanation {
                ExplanationBox(label: "쉽게 설명", text: easy)
            }
            sectionButtons
            sectionDetail
            footer
        }
    }

    private var sectionButtons: some View {
        HStack(spacing: 8) {
            sectionButton(.details, "자세히 보기", "doc.text")
            sectionButton(.examples, "예시", "text.quote")
            sectionButton(.related, "관련 개념", "point.3.connected.trianglepath.dotted")
        }
    }

    private func sectionButton(_ section: ExpandedSection, _ title: String, _ icon: String) -> some View {
        Button {
            model.expandedSection = model.expandedSection == section ? nil : section
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(model.expandedSection == section ? Color.green : nil)
    }

    @ViewBuilder
    private var sectionDetail: some View {
        switch model.expandedSection {
        case .details:
            if let oneLine = entry.oneLine {
                HighlightBox(text: oneLine)
            } else {
                PlaceholderBox(text: "한 줄 요약이 아직 없어요.")
            }
        case .examples:
            PlaceholderBox(text: "예시 문장은 준비 중이에요. 곧 추가될 예정이에요.")
        case .related:
            PlaceholderBox(text: "관련 개념 목록을 준비 중이에요.")
        case nil:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("추가 질문") { model.onFollowUp?() }
                .frame(maxWidth: .infinity)
            Button("수정") { model.onEdit?() }
                .frame(maxWidth: .infinity)
            Button("다시 조사") { model.onRetry?() }
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - researching(query:)

private struct ResearchingStateView: View {
    let query: String
    @ObservedObject var model: PanelModel

    @State private var completedSteps = 0
    private let steps = ["의미를 파악하고 있어요", "관련 자료를 검색하고 있어요", "AI가 정리하고 있어요"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(query)
                .font(.headline)
                .lineLimit(2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(steps.indices, id: \.self) { index in
                    HStack(spacing: 10) {
                        stepIcon(index)
                        Text(steps[index])
                            .font(.system(size: 13, weight: index == completedSteps ? .semibold : .regular))
                            .foregroundStyle(index <= completedSteps ? Color.primary : Color.secondary)
                    }
                }
            }
            Spacer()
            HStack {
                Button("취소") { model.onCancel?() }
                    .buttonStyle(.bordered)
            }
            Text("보통 5~15초 정도 소요됩니다")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            completedSteps = 0
            for _ in 0..<steps.count {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                completedSteps += 1
            }
        }
    }

    @ViewBuilder
    private func stepIcon(_ index: Int) -> some View {
        if index < completedSteps {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
        } else if index == completedSteps {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: "circle")
                .foregroundStyle(Color.secondary.opacity(0.5))
        }
    }
}

// MARK: - result(_:sources:saved:)

private struct ResultStateView: View {
    let entry: DictionaryEntry
    let sources: [PanelModel.PanelSource]
    let saved: Bool
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(entry.preferredTerm)
                .font(.system(size: 22, weight: .bold))
            HStack(spacing: 6) {
                ChipView(text: "AI", tint: .blue)
                ChipView(text: saved ? "사전에 저장됨 ✓" : "임시 결과", tint: saved ? .green : .gray)
            }
            if let oneLine = entry.oneLine {
                Text(oneLine)
                    .font(.system(size: 14))
                    .lineSpacing(4)
            }
            if let easy = entry.easyExplanation {
                ExplanationBox(label: "쉽게 설명", text: easy)
            }
            if !sources.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("출처")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(index + 1).")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            if let url = source.url {
                                Link(source.title, destination: url)
                                    .font(.system(size: 13))
                            } else {
                                Text(source.title)
                                    .font(.system(size: 13))
                            }
                        }
                    }
                }
            }
            if !saved {
                Text("임시 결과예요. 마음에 들면 수정에서 사전으로 저장할 수 있어요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("수정") { model.onEdit?() }
                    .frame(maxWidth: .infinity)
                Button("다시 조사") { model.onRetry?() }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - empty(query:)

private struct EmptyStateView: View {
    let query: String
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("사전에 없는 개념이에요")
                .font(.system(size: 17, weight: .semibold))
            Text("\"\(query)\"에 대한 의미와 자료를 AI가 찾아 정리해 드릴게요.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("조사 시작") { model.onRetry?() }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - failed(query:message:)

private struct FailedStateView: View {
    let message: String
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(Color.orange)
            Text("조사에 실패했어요")
                .font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("다시 시도") { model.onRetry?() }
                .buttonStyle(.borderedProminent)
                .tint(.green)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared pieces

private struct ChipView: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.14)))
            .foregroundStyle(tint)
    }
}

private struct ExplanationBox: View {
    let label: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }
}

private struct HighlightBox: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .lineSpacing(3)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.12)))
    }
}

private struct PlaceholderBox: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }
}
