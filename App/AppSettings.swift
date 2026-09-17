import AppKit
import Foundation
import LexiCore

enum AppIconPlacement: String, CaseIterable, Identifiable {
    case menuBarAndDock
    case menuBarOnly
    case dockOnly

    static let storageKey = "appIconPlacement"
    static let defaultValue = AppIconPlacement.menuBarAndDock

    var id: String { rawValue }

    init(stored: String?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? Self.defaultValue
    }

    var showsMenuBarIcon: Bool { self != .dockOnly }
    var showsDockIcon: Bool { self != .menuBarOnly }

    var activationPolicy: NSApplication.ActivationPolicy {
        showsDockIcon ? .regular : .accessory
    }

    var label: String {
        switch self {
        case .menuBarAndDock: "메뉴 막대와 Dock"
        case .menuBarOnly: "메뉴 막대만"
        case .dockOnly: "Dock만"
        }
    }

    func settingMenuBarIconVisible(_ isVisible: Bool) -> AppIconPlacement {
        switch (isVisible, showsDockIcon) {
        case (true, true): .menuBarAndDock
        case (true, false): .menuBarOnly
        case (false, _): .dockOnly
        }
    }
}

enum ExplanationLanguagePreference: Hashable {
    case auto
    case fixed(EntryLanguage)

    static let storageKey = "explanationLanguage"

    /// 저장된 값을 복원한다. 값이 없거나 잘못됐으면 기본값(한국어 고정)이다.
    init(stored: String?) {
        if stored == "auto" {
            self = .auto
        } else if let language = stored.flatMap(EntryLanguage.init(rawValue:)) {
            self = .fixed(language)
        } else {
            self = .fixed(.korean)
        }
    }

    var storageValue: String {
        switch self {
        case .auto: "auto"
        case .fixed(let language): language.rawValue
        }
    }

    /// 파이프라인이 실제 생성·조회에 쓰는 언어를 확정한다.
    func resolve(termLanguage: EntryLanguage?) -> EntryLanguage {
        switch self {
        case .auto: termLanguage ?? .korean
        case .fixed(let language): language
        }
    }

    var label: String {
        switch self {
        case .auto: "자동 · 조회 언어 따르기"
        case .fixed(let language): language.koreanName
        }
    }

    static let all: [ExplanationLanguagePreference] =
        [.auto] + EntryLanguage.allCases.map { .fixed($0) }
}

struct EngineSettings: Equatable {
    static let defaultModelID = "mlx-community/Qwen3-4B-4bit"
    let modelID: String
    let webResearchAllowed: Bool
    let explanationLanguage: ExplanationLanguagePreference
    /// 조회 오타 자동 보정. 기본 켜짐. 끄면 조회가 원본 텍스트를 그대로 쓴다.
    static let typoCorrectionStorageKey = "autoCorrectTypos"
    let typoCorrectionEnabled: Bool

    init(defaults: UserDefaults = .standard) {
        let stored = defaults.string(forKey: "mlxModelID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        modelID = Self.isValidModelID(stored) ? stored : Self.defaultModelID
        webResearchAllowed = defaults.bool(forKey: "webResearchAllowed")
        typoCorrectionEnabled = defaults.object(forKey: Self.typoCorrectionStorageKey) as? Bool ?? true
        explanationLanguage = ExplanationLanguagePreference(
            stored: defaults.string(forKey: ExplanationLanguagePreference.storageKey))
    }

    static func isValidModelID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }
}

extension Notification.Name {
    static let lexiLibraryChanged = Notification.Name("lexiLibraryChanged")
}

enum SystemSettings {
    static func openAccessibility() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openServices() {
        open("x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts")
    }

    private static func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Presets use the same Qwen3 architecture supported by the bundled MLX runtime.
enum ModelChoice: String, CaseIterable, Identifiable {
    case balanced = "mlx-community/Qwen3-4B-4bit"
    case light = "mlx-community/Qwen3-1.7B-4bit"
    case large = "mlx-community/Qwen3-8B-4bit"
    case custom = "custom"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .balanced: "Qwen3 4B · 기본"
        case .light: "Qwen3 1.7B · 가벼운 모델"
        case .large: "Qwen3 8B · 큰 모델"
        case .custom: "사용자 지정…"
        }
    }
    var description: String {
        switch self {
        case .balanced: "일상적인 개념 설명에 사용할 기본 4-bit 모델이에요."
        case .light: "더 작은 4-bit 모델로 메모리 사용량을 줄일 수 있어요. 설명의 정확도는 직접 확인해 주세요."
        case .large: "더 큰 4-bit 모델이에요. 메모리와 저장 공간이 더 필요하고 준비 시간이 길어질 수 있어요."
        case .custom: "Hugging Face의 MLX 호환 모델 ID를 직접 입력해 주세요."
        }
    }
    static func matching(_ modelID: String) -> ModelChoice {
        allCases.first { $0 != .custom && $0.rawValue == modelID } ?? .custom
    }
}
