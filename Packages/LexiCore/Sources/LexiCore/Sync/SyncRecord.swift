import Foundation

/// 동기화 행 참조. (kind, uuid)가 행의 전체 정체성이다. SQLite autoincrement ID는
/// 기기마다 다르므로 동기화에서는 절대 쓰지 않는다.
public struct SyncRecordRef: Sendable, Equatable, Codable, Hashable {
    public let kind: SyncKind
    public let uuid: String

    public init(kind: SyncKind, uuid: String) {
        self.kind = kind
        self.uuid = uuid
    }
}

/// 동기화 행 스냅샷. 네 종류의 행을 하나의 평면 구조로 담는다. CloudKit 레코드와
/// 미적용 보관함(syncPendingRemote JSON) 양쪽에 쓰이므로 Codable이다.
/// kind별로 쓰지 않는 필드는 nil이다.
public struct SyncRecord: Sendable, Equatable, Codable {
    public let kind: SyncKind
    public let uuid: String
    /// alias·revision → 부모 concept uuid, source → 부모 revision uuid. concept은 nil.
    public let parentUUID: String?

    // concept
    public var preferredTerm: String?
    public var field: String?
    public var isFavorite: Bool?

    // 공통 메타
    public var lang: String?
    public var createdAt: Date?
    public var updatedAt: Date?

    // revision
    public var oneLine: String?
    public var easyExplanation: String?
    public var author: String?
    public var provider: String?

    // alias
    public var text: String?

    // source
    public var title: String?
    public var url: String?
    public var excerpt: String?
    public var retrievedAt: Date?

    public init(
        kind: SyncKind,
        uuid: String,
        parentUUID: String? = nil,
        preferredTerm: String? = nil,
        field: String? = nil,
        isFavorite: Bool? = nil,
        lang: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        oneLine: String? = nil,
        easyExplanation: String? = nil,
        author: String? = nil,
        provider: String? = nil,
        text: String? = nil,
        title: String? = nil,
        url: String? = nil,
        excerpt: String? = nil,
        retrievedAt: Date? = nil
    ) {
        self.kind = kind
        self.uuid = uuid
        self.parentUUID = parentUUID
        self.preferredTerm = preferredTerm
        self.field = field
        self.isFavorite = isFavorite
        self.lang = lang
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.oneLine = oneLine
        self.easyExplanation = easyExplanation
        self.author = author
        self.provider = provider
        self.text = text
        self.title = title
        self.url = url
        self.excerpt = excerpt
        self.retrievedAt = retrievedAt
    }
}
