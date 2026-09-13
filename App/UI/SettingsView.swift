import AppKit
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case general = "일반"
        case model = "AI 모델"
        case research = "웹 조사"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "keyboard"
            case .model: "cpu"
            case .research: "globe"
            }
        }
    }

    @AppStorage("mlxModelID") private var savedModelID = EngineSettings.defaultModelID
    @EnvironmentObject private var appDelegate: AppDelegate
    @AppStorage("customMLXModelID") private var customModelID = ""
    @AppStorage("webResearchAllowed") private var webResearchAllowed = false
    @State private var page: Page = .general
    @AppStorage(ExplanationLanguagePreference.storageKey) private var explanationLanguageStored = "ko"
    @State private var modelDraft = ""
    @State private var modelChoice: ModelChoice = .balanced
    @State private var accessibilityGranted = false
    @State private var serviceRefreshed = false
    @State private var modelSaved = false

    private var normalizedModel: String { modelDraft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                Label("Lexi", systemImage: "character.book.closed.fill")
                    .font(.title2.bold())
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 12)
                    .padding(.top, 24)
                VStack(spacing: 6) {
                    ForEach(Page.allCases) { item in
                        Button {
                            page = item
                        } label: {
                            Label(item.rawValue, systemImage: item.icon)
                                .font(.body.weight(page == item ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(page == item ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(page == item ? Color.accentColor : .primary)
                    }
                }
                Spacer()
                Text("나만의 개념 사전")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            .padding(.horizontal, 12)
            .frame(width: 156)
            .background(.quaternary.opacity(0.3))
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(page.rawValue).font(.title2.bold()).padding(.horizontal, 24).padding(.top, 24)
                Form {
                    switch page {
                    case .general: generalSettings
                    case .model: modelSettings
                    case .research: researchSettings
                    }
                }
                .formStyle(.grouped)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            modelChoice = ModelChoice.matching(savedModelID)
            modelDraft = modelChoice == .custom ? savedModelID : customModelID
            refreshPermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermission()
        }
    }

    private var explanationLanguage: Binding<ExplanationLanguagePreference> {
        Binding(
            get: { ExplanationLanguagePreference(stored: explanationLanguageStored) },
            set: { explanationLanguageStored = $0.storageValue }
        )
    }

    private var iconPlacement: Binding<AppIconPlacement> {
        Binding(
            get: { appDelegate.iconPlacement },
            set: { appDelegate.updateIconPlacement($0) }
        )
    }

    private var generalSettings: some View {
        Group {
            Section {
                Picker("아이콘 표시 위치", selection: iconPlacement) {
                    ForEach(AppIconPlacement.allCases) { placement in
                        Text(placement.label).tag(placement)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("아이콘을 숨겨도 Lexi는 계속 실행됩니다. 앱을 다시 열 수 있도록 메뉴 막대나 Dock 중 한 곳에는 항상 표시해요.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("앱 표시") }

            Section {
                Picker("설명 언어", selection: explanationLanguage) {
                    ForEach(ExplanationLanguagePreference.all, id: \.storageValue) { preference in
                        Text(preference.label).tag(preference)
                    }
                }
                Text("AI가 만드는 정의와 설명의 언어예요. **자동**은 조회한 용어의 언어를 따르고 판단에 실패하면 한국어로 설명해요. 이미 저장된 항목은 그 언어로 쓰인 설명이 있을 때 우선 보여요.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("언어") }

            Section {
                KeyboardShortcuts.Recorder("선택한 텍스트 조회", name: .lookupSelection)
                Text("다른 앱에서 텍스트를 선택한 뒤 누르세요. 자주 쓰는 단축키와 겹치면 여기서 바꿀 수 있어요.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("단축키") }

            Section {
                LabeledContent("손쉬운 사용 권한") {
                    Label(accessibilityGranted ? "허용됨" : "설정 필요", systemImage: accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(accessibilityGranted ? .green : .orange)
                }
                Text("단축키로 다른 앱의 선택 영역을 읽을 때 필요해요. 우클릭 서비스는 이 권한 없이 사용할 수 있어요.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("손쉬운 사용 설정 열기…") {
                    SystemSettings.openAccessibility()
                }
                if !accessibilityGranted {
                    Text("설정에서 Lexi를 켠 뒤 돌아오면 자동으로 다시 확인해요. 이미 켜져 있다면 껐다가 다시 켜 주세요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("접근 권한") }

            Section {
                Label("Lexi에게 물어보기", systemImage: "questionmark.bubble")
                    .fontWeight(.medium)
                Text("텍스트 선택 → 우클릭 → 서비스 → Lexi에게 물어보기에서 사용할 수 있어요. macOS 서비스는 호출 앱이 메뉴 위치를 정하므로 Lexi가 최상위에 고정할 수 없어요. 더 빠른 호출은 위 전역 단축키를 사용하거나, 권한 없이 쓰려면 서비스 설정에서 별도 단축키를 지정하세요.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("서비스 단축키 설정 열기…") { SystemSettings.openServices() }
                    Button("목록 새로고침") {
                        AppDelegate.refreshServices()
                        serviceRefreshed = true
                    }
                }
                if serviceRefreshed {
                    Text("등록 정보를 새로고쳤어요. 사용하던 앱에서 메뉴를 다시 열어 주세요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("우클릭 서비스") }
        }
    }

    private var modelSettings: some View {
        Group {
            Section {
                Label("이 Mac에서 실행", systemImage: "desktopcomputer")
                    .font(.headline)
                Text("Apple Silicon의 MLX 모델로 설명을 만들어요. 저장된 개념은 모델을 실행하지 않고 바로 보여 줍니다.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("사용할 모델", selection: Binding(
                    get: { modelChoice },
                    set: { choice in
                        modelChoice = choice
                        modelSaved = false
                        if choice != .custom {
                            savedModelID = choice.rawValue
                            modelSaved = true
                        }
                    }
                )) {
                    ForEach(ModelChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                Text(modelChoice.description).font(.callout).foregroundStyle(.secondary)
                if modelChoice == .custom {
                    TextField("Hugging Face 모델 ID", text: $modelDraft, prompt: Text("소유자/모델 이름"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: modelDraft) { _, newValue in
                            // 정규화만으로 저장된 ID와 같아지는 편집은 저장 확인을 지우지 않는다.
                            if newValue.trimmingCharacters(in: .whitespacesAndNewlines) != savedModelID {
                                modelSaved = false
                            }
                        }
                    if !normalizedModel.isEmpty, !EngineSettings.isValidModelID(normalizedModel) {
                        Label("소유자/모델 이름 형식으로 입력해 주세요.", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Link("MLX 모델 찾아보기", destination: URL(string: "https://huggingface.co/models?library=mlx")!)
                        Spacer()
                        Button("적용") {
                            savedModelID = normalizedModel
                            customModelID = normalizedModel
                            modelDraft = normalizedModel
                            modelSaved = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!EngineSettings.isValidModelID(normalizedModel) || normalizedModel == savedModelID)
                    }
                }
                if modelSaved {
                    Label("저장했어요. 다음 조회부터 적용됩니다.", systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.green)
                }
            } header: { Text("로컬 모델") } footer: {
                Text("기본 제공 모델은 선택하면 바로 저장됩니다. 처음 사용하는 모델은 조회할 때 Hugging Face에서 내려받으므로 네트워크 연결과 수 GB의 여유 공간이 필요할 수 있어요.")
            }

            Section {
                Text("현재 사용 중인 모델").font(.caption).foregroundStyle(.secondary)
                Text(savedModelID).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            }
        }
    }

    private var researchSettings: some View {
        Section {
            Toggle("공개 웹 자료 검색", isOn: $webResearchAllowed)
            Text(webResearchAllowed
                 ? "새 개념을 조회할 때 DuckDuckGo 검색과 공개 웹페이지를 참고합니다. 실제로 읽은 자료만 출처로 저장해요."
                 : "로컬 모델의 지식으로 설명을 만듭니다. 결과에는 외부 출처가 없는 AI 초안임을 표시해요.")
                .foregroundStyle(.secondary)
            Label("변경은 다음 조회부터 바로 적용됩니다.", systemImage: "checkmark.circle")
                .font(.callout).foregroundStyle(.secondary)
        } header: { Text("웹 조사") } footer: {
            Text("켜면 조회한 텍스트가 검색 서비스로 전송되고 공개 웹페이지에 접속합니다. 이미 저장된 개념을 열 때는 웹 검색을 실행하지 않아요.")
        }
    }

    private func refreshPermission() {
        accessibilityGranted = SelectedTextReader.isAccessibilityGranted(promptIfNeeded: false)
    }
}
