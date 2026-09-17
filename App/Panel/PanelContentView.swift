import SwiftUI
import LexiCore

struct PanelContentView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "character.book.closed.fill").foregroundStyle(Color.accentColor)
                Text("Lexi").font(.headline)
                Spacer()
                Button { model.onSettings?() } label: {
                    Image(systemName: "gearshape")
                }.help("설정").accessibilityLabel("설정")
                Button { model.onClose?() } label: {
                    Image(systemName: "xmark").padding(4)
                }.help("닫기 (Esc)").accessibilityLabel("닫기")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.state {
                    case .hit(let entry, let correction):
                        if let correction {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("오타 자동 보정으로 찾았어요", systemImage: "wand.and.stars")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Text("“\(correction.original)” → “\(correction.replacement)”")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        entryContent(entry, sources: [], newlySaved: false)
                    case .result(let entry, let sources, let saved):
                        entryContent(entry, sources: sources, newlySaved: saved)
                    case .researching(let query):
                        Text(query).font(.title2.bold())
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text("개념의 설명을 만들고 있어요").font(.headline)
                        }
                        Text("처음 사용하는 모델은 다운로드와 준비에 시간이 걸릴 수 있어요. 완료되면 사전에 자동 저장됩니다.")
                            .foregroundStyle(.secondary).lineSpacing(4)
                        Button("조회 취소") { model.onCancel?() }.buttonStyle(.bordered)
                    case .failed(let query, let message):
                        Text(query).font(.title2.bold())
                        Label("설명을 만들지 못했어요", systemImage: "exclamationmark.triangle")
                            .font(.headline).foregroundStyle(.orange)
                        Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Button("다시 시도") { model.onRetry?() }.buttonStyle(.borderedProminent)
                            Button("모델 설정") { model.onSettings?() }.buttonStyle(.bordered)
                        }
                    case .empty(let query):
                        Text(query.isEmpty ? "어떤 개념이 궁금한가요?" : query).font(.title2.bold())
                        Text("텍스트를 선택하고 단축키 또는 우클릭 서비스를 사용해 보세요.")
                            .foregroundStyle(.secondary)
                        Button("내 사전 열기") { model.onEdit?() }.buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func entryContent(_ entry: DictionaryEntry, sources: [PanelModel.PanelSource], newlySaved: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Text(entry.preferredTerm).font(.system(size: 26, weight: .bold)).textSelection(.enabled)
                if let language = entry.explanationLanguage ?? entry.termLanguage {
                    Text(language.koreanName)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.indigo.opacity(0.15)))
                        .foregroundStyle(.indigo)
                        .padding(.top, 7)
                        .help("이 설명의 언어")
                }
                Spacer()
                if entry.isFavorite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("즐겨찾기")
                }
            }
            Label(newlySaved ? "내 사전에 저장했어요" : "내 사전에 저장된 개념", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium)).foregroundStyle(.green)
            if let oneLine = entry.oneLine, !oneLine.isEmpty {
                Text(oneLine).font(.headline).lineSpacing(4).textSelection(.enabled)
            }
            if let explanation = entry.easyExplanation, !explanation.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("쉽게 이해하기").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(explanation).lineSpacing(4).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
            if entry.author == "ai" {
                Label(newlySaved && sources.isEmpty ? "AI 초안 · 외부 출처 없음" : "AI가 작성한 설명", systemImage: "sparkles")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !sources.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("참고한 출처").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(sources) { source in
                        if let url = source.url {
                            Link(source.title, destination: url).font(.callout)
                        } else {
                            Text(source.title).font(.callout)
                        }
                    }
                }
            }
            Button { model.onEdit?() } label: {
                Label("사전에서 열기", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }
}
