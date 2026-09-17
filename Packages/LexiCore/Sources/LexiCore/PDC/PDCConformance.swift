import Foundation

/// PDC(Portable Document Contract) v2 계약 상수와 conformance corpus 색인.
///
/// 여기 담는 이름은 전부 docs/PDC-MIGRATION.md가 문서로 고정한 외부 계약이다.
/// Lexi 전용 문법을 만들지 않고, 외부 정본(`pdc-document/2`, 표준 commit 0ee51ea)을 따른다.
public enum PDCContract {
    /// 현재 문서 계약. v1(`pdc-document/1`, Djot 우선)은 읽기 전용 legacy로 남는다.
    public static let documentContract = "pdc-document/2"
    /// canonical ordinary 문서 프로파일: Obsidian 호환 lowercase `.md`.
    public static let markdownProfile = "pdc-markdown/1"
    /// authored HTML이 중요할 때의 first-class readable 입력.
    public static let htmlProfile = "pdc-html/1"
    /// 쿼리 블록 별도 계약. 데이터로만 보존하고 절대 실행하지 않는다.
    public static let queryProfile = "pdc-query/1"
    /// v1 legacy 프로파일(읽기 전용).
    public static let legacyDjotProfile = "pdc-djot/1"
    public static let legacyDocumentContract = "pdc-document/1"

    /// 개정·출처 전체 구조를 opaque JSON으로 보존하는 사용자 property.
    /// 다른 앱은 이 property를 그대로 왕복한다.
    public static let revisionHistoryProperty = "lexi_revision_history_json"
    /// SQLite autoincrement ID(legacy concept ID)를 보존하는 사용자 property.
    public static let legacyIDProperty = "lexi_legacy_id"
    /// concept ↔ PDC 문서 UUID 영구 매핑 테이블. Stage 2 마이그레이션에서 추가된다.
    public static let documentMapTable = "pdc_document_map"

    /// conformance suite 식별자와 이 저장소가 고정한 revision.
    public static let conformanceFormat = "pdc-document-conformance/2"
    public static let conformanceRevision = 2
}

/// `pdc-document-conformance/2` corpus.json의 색인. 계약 고정(Stage 0)용으로
/// 판독만 한다. 판단 로직(codec, import plan)은 Stage 1 이후 별도로 붙는다.
public struct PDCConformanceCorpus: Sendable, Equatable, Decodable {
    /// 케이스 한 건. kind에 따라 쓰는 필드가 다르다.
    /// - file: `path`
    /// - operation: `operation`, `input`, (선택) `expected`, `patch`
    /// - set: `paths`
    public struct Case: Sendable, Equatable, Decodable {
        public let id: String
        public let kind: String
        public let path: String?
        public let paths: [String]?
        public let operation: String?
        public let input: String?
        public let expected: String?
        public let expect: String

        /// 케이스가 참조하는 모든 fixture 상대 경로.
        public var referencedPaths: [String] {
            ([path] + (paths ?? []) + [input, expected]).compactMap { $0 }
        }
    }

    public let format: String
    public let revision: Int
    public let markdownBaseline: String
    public let queryContract: String
    public let bodyProfiles: [String]
    public let cases: [Case]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        revision = try container.decode(Int.self, forKey: .revision)
        markdownBaseline = try container.decode(String.self, forKey: .markdownBaseline)
        queryContract = try container.decode(String.self, forKey: .queryContract)
        bodyProfiles = try container.decode([String].self, forKey: .bodyProfiles)
        cases = try container.decode([Case].self, forKey: .cases)
    }

    private enum CodingKeys: String, CodingKey {
        case format, revision, markdownBaseline, queryContract, bodyProfiles, cases
    }
}
