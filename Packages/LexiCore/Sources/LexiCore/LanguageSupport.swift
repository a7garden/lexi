import Foundation
import NaturalLanguage

/// 사전 항목·설명의 언어.
///
/// rawValue는 `alias.lang`(v1), `concept.lang`·`definitionRevision.lang`(v2) 컬럼과
/// PDC `lang` 매핑이 쓰는 기본 언어 태그다. 지원 목록 밖의 태그는 `decode`가 nil을
/// 돌려주므로, 미래 언어 확장에도 조회 동작은 깨지지 않는다.
public enum EntryLanguage: String, Sendable, CaseIterable, Equatable {
    case korean = "ko"
    case english = "en"
    case japanese = "ja"
    case chinese = "zh"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case russian = "ru"

    /// 프롬프트 지시에 쓰는 현지어 자칭. 모델이 언어를 가장 잘 따르는 표기다.
    public var nativeName: String {
        switch self {
        case .korean: "한국어"
        case .english: "English"
        case .japanese: "日本語"
        case .chinese: "简体中文"
        case .french: "Français"
        case .german: "Deutsch"
        case .spanish: "Español"
        case .russian: "Русский"
        }
    }

    /// 한국어 UI 표시명.
    public var koreanName: String {
        switch self {
        case .korean: "한국어"
        case .english: "영어"
        case .japanese: "일본어"
        case .chinese: "중국어"
        case .french: "프랑스어"
        case .german: "독일어"
        case .spanish: "스페인어"
        case .russian: "러시아어"
        }
    }

    /// DB에 저장된 태그를 되돌린다. 미지원 태그·NULL은 nil.
    public static func decode(_ rawValue: String?) -> EntryLanguage? {
        rawValue.flatMap(Self.init(rawValue:))
    }
}

/// 조회 용어와 설명 텍스트의 언어를 추정한다.
///
/// 문자 종족(script) 분포가 결정적 신호(가나→일본어, 한글→한국어)를 주면 그대로 판정하고,
/// 나머지는 NLLanguageRecognizer에 맡긴다. 판단 근거가 없거나 ``EntryLanguage`` 지원
/// 목록 밖이면 nil을 돌려준다. nil은 오류가 아니라 "언어 메타데이터를 채우지 않는다"는
/// 뜻이며, 조회·생성 동작은 설정값을 따른다.
public enum LanguageDetector {
    public static func detect(_ text: String) -> EntryLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var hangul = 0, kana = 0, han = 0, latin = 0, cyrillic = 0
        for scalar in trimmed.unicodeScalars {
            switch scalar.value {
            case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F:
                hangul += 1
            case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
                kana += 1
            case 0x2E80...0x2EFF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
                han += 1
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF:
                latin += 1
            case 0x0400...0x04FF, 0x0500...0x052F:
                cyrillic += 1
            default:
                break  // 공백·숫자·구두점 등 언어 판별에 쓰지 않는 문자
            }
        }
        // 가나는 일본어의, 한글은 한국어의 결정적 신호다.
        if kana > 0 { return .japanese }
        if hangul > 0 { return .korean }

        // 가나가 없는 한자 텍스트는 중국어로 판정한다(번체 포함). 일본어 텍스트는 실제
        // 용례에서 가나를 거의 항상 포함하므로, 한자 단독("寿司", "時間")은 중국어·일본어
        // 어느 쪽 문자로도 읽히는 영역이고 통계적 사전확률은 중국어가 압도적이다.
        // 인식기에 맡기면 짧은 용어에서 판정이 뒤집히므로 결정적으로 고정한다.
        if han > 0 { return .chinese }

        // 라틴·키릴 등은 문자만으로 언어가 갈리므로 인식기에 맡긴다. 지원 목록 밖
        // (이탈리아어, 우크라이나어 등)은 nil로 무표기한다.
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        switch recognizer.dominantLanguage {
        case .korean: return .korean
        case .english: return .english
        case .japanese: return .japanese
        case .simplifiedChinese, .traditionalChinese: return .chinese
        case .french: return .french
        case .german: return .german
        case .spanish: return .spanish
        case .russian: return .russian
        default: return nil
        }
    }
}
