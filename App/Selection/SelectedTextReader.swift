import AppKit
import ApplicationServices

/// 선택 텍스트 읽기 실패 사유.
public enum SelectedTextError: LocalizedError, Equatable {
    /// 접근성 권한 없음
    case notTrusted
    /// 포커스 앱이 선택 텍스트를 노출하지 않음
    case selectionUnavailable(appName: String?)

    public var errorDescription: String? {
        switch self {
        case .notTrusted:
            return "선택한 텍스트를 읽으려면 손쉬운 사용 권한이 필요합니다. Lexi 설정 > 일반 > 접근 권한에서 Lexi를 허용해 주세요."
        case .selectionUnavailable(let appName):
            let app = appName ?? "현재 앱"
            return "\(app)에서 선택된 텍스트를 가져올 수 없습니다. 텍스트를 선택한 후 다시 시도해 주세요."
        }
    }
}

/// 접근성(Accessibility) API로 포커스 앱의 선택 텍스트를 읽는다.
///
/// 설계 규칙: 어떤 경우에도 클립보드를 건드리지 않는다 — Cmd+C 폴백으로
/// 클립보드를 선택 텍스트인 양 쓰지 않는다. 실패는 명시적 에러로 보고한다.
public enum SelectedTextReader {
    /// 접근성 권한 보유 여부.
    /// - Parameter promptIfNeeded: true면 시스템 권한 프롬프트를 띄운다.
    public static func isAccessibilityGranted(promptIfNeeded: Bool) -> Bool {
        // kAXTrustedCheckOptionPrompt는 C 전역 var라 Swift 6 동시성 검사를 통과하지 못한다.
        // 실체는 변경되지 않는 키 문자열이므로 동일 리터럴을 사용한다.
        let options = ["AXTrustedCheckOptionPrompt": promptIfNeeded] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 포커스 앱의 선택 텍스트를 trim해서 반환한다.
    ///
    /// 1차로 시스템와이드 포커스 엘리먼트에서 `kAXSelectedTextAttribute`를 읽고,
    /// 실패하면 포그라운드 앱의 pid로 `AXUIElementCreateApplication`을 만들어 재시도한다.
    /// 둘 다 실패하거나 빈 문자열이면 `.selectionUnavailable(appName:)`을 던진다.
    /// - Throws: `SelectedTextError.notTrusted`, `SelectedTextError.selectionUnavailable(appName:)`
    @MainActor
    public static func readSelectedText() throws -> String {
        guard isAccessibilityGranted(promptIfNeeded: false) else {
            throw SelectedTextError.notTrusted
        }
        let frontmost = NSWorkspace.shared.frontmostApplication

        // 1차: 시스템와이드 포커스 엘리먼트
        var selected = selectedText(from: AXUIElementCreateSystemWide(), readingFocused: true)
        // 2차: 포그라운드 앱 pid로 직접 질의
        if selected == nil, let app = frontmost {
            selected = selectedText(from: AXUIElementCreateApplication(app.processIdentifier), readingFocused: false)
        }

        guard let text = selected else {
            throw SelectedTextError.selectionUnavailable(appName: frontmost?.localizedName)
        }
        return text
    }

    /// element(readingFocused=true면 그 포커스 엘리먼트)에서 선택 텍스트를 읽어 trim해 돌려준다.
    /// 실패하거나 trim 결과가 비면 nil.
    private static func selectedText(from element: AXUIElement, readingFocused: Bool) -> String? {
        var target = element
        if readingFocused {
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let node = focused else {
                return nil
            }
            target = node as! AXUIElement
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
