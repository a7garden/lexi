import CloudKit
import Foundation

/// SyncRecord ↔ CKRecord 변환. 레코드 이름은 "kind-uuid"로 정해서, CloudKit이
/// 삭제 이벤트로 recordID만 돌려줄 때도 kind와 uuid를 되찾는다.
///
/// 부모 관계는 두 갈래로 기록한다:
/// - `record["parentUUID"]` 필드: 로컬 적용(apply)이 읽는 데이터.
/// - `record.parent` 참조: 서버 위계 표시. CloudKit 규칙상 action은 반드시 none이고
///   cascade 삭제도 없다 — 삭제 전파는 자식 묘비가 명시적으로 한다.
extension SyncRecord {
    public var cloudRecordName: String { "\(kind.rawValue)-\(uuid)" }

    public var cloudRecordID: CKRecord.ID {
        CKRecord.ID(recordName: cloudRecordName)
    }

    /// 부모 레코드 ID. alias·revision은 concept, source는 revision을 부모로 둔다.
    var parentRecordID: CKRecord.ID? {
        guard let parentUUID else { return nil }
        let parentKind: SyncKind = kind == .source ? .revision : .concept
        return CKRecord.ID(recordName: "\(parentKind.rawValue)-\(parentUUID)")
    }

    /// 새 CKRecord를 만들어 필드를 채운다.
    public func makeCKRecord() -> CKRecord {
        let record = CKRecord(recordType: kind.rawValue, recordID: cloudRecordID)
        apply(to: record)
        return record
    }

    /// 기존 CKRecord에 스냅샷 필드를 채운다(충돌 해결 재저장에도 쓴다).
    public func apply(to record: CKRecord) {
        if let parentUUID {
            record["parentUUID"] = parentUUID
            if let parentRecordID {
                record.parent = CKRecord.Reference(recordID: parentRecordID, action: .none)
            }
        }
        switch kind {
        case .concept:
            record["preferredTerm"] = preferredTerm
            record["field"] = field
            if let isFavorite { record["isFavorite"] = NSNumber(value: isFavorite) }
            record["lang"] = lang
            record["createdAt"] = createdAt
            record["updatedAt"] = updatedAt
        case .revision:
            record["oneLine"] = oneLine
            record["easyExplanation"] = easyExplanation
            record["author"] = author
            record["provider"] = provider
            record["lang"] = lang
            record["createdAt"] = createdAt
        case .alias:
            record["text"] = text
            record["lang"] = lang
        case .source:
            record["title"] = title
            record["url"] = url
            record["excerpt"] = excerpt
            record["retrievedAt"] = retrievedAt
        }
    }

    /// CKRecord를 스냅샷으로 되찾는다. 모르는 recordType·깨진 이름은 nil(진단 대상).
    public init?(cloudRecord: CKRecord) {
        guard let kind = SyncKind(rawValue: cloudRecord.recordType),
              let uuid = Self.uuid(fromRecordName: cloudRecord.recordID.recordName, kind: kind)
        else { return nil }
        let parentName = cloudRecord.parent?.recordID.recordName
        let parentUUID = (cloudRecord["parentUUID"] as? String)
            ?? parentName.flatMap {
                Self.uuid(fromRecordName: $0, kind: kind == .source ? .revision : .concept)
            }
        self.init(kind: kind, uuid: uuid, parentUUID: parentUUID)
        switch kind {
        case .concept:
            preferredTerm = cloudRecord["preferredTerm"] as? String
            field = cloudRecord["field"] as? String
            isFavorite = (cloudRecord["isFavorite"] as? NSNumber)?.boolValue
            lang = cloudRecord["lang"] as? String
            createdAt = cloudRecord["createdAt"] as? Date
            updatedAt = cloudRecord["updatedAt"] as? Date
        case .revision:
            oneLine = cloudRecord["oneLine"] as? String
            easyExplanation = cloudRecord["easyExplanation"] as? String
            author = cloudRecord["author"] as? String
            provider = cloudRecord["provider"] as? String
            lang = cloudRecord["lang"] as? String
            createdAt = cloudRecord["createdAt"] as? Date
        case .alias:
            text = cloudRecord["text"] as? String
            lang = cloudRecord["lang"] as? String
        case .source:
            title = cloudRecord["title"] as? String
            url = cloudRecord["url"] as? String
            excerpt = cloudRecord["excerpt"] as? String
            retrievedAt = cloudRecord["retrievedAt"] as? Date
        }
    }

    /// "concept-0198…" → "0198…". 접두어가 kind와 일치해야 한다.
    public static func uuid(fromRecordName name: String, kind: SyncKind) -> String? {
        let prefix = kind.rawValue + "-"
        guard name.hasPrefix(prefix) else { return nil }
        let uuid = String(name.dropFirst(prefix.count))
        return uuid.isEmpty ? nil : uuid
    }
}

extension SyncRecordRef {
    /// 레코드 이름에서 되찾는다. CloudKit 삭제 이벤트는 레코드 ID만 주므로 필요하다.
    public init?(cloudRecordName: String) {
        for kind in SyncKind.allCases {
            if let uuid = SyncRecord.uuid(fromRecordName: cloudRecordName, kind: kind) {
                self.init(kind: kind, uuid: uuid)
                return
            }
        }
        return nil
    }

    public init?(cloudRecordID: CKRecord.ID) {
        self.init(cloudRecordName: cloudRecordID.recordName)
    }

    public var cloudRecordID: CKRecord.ID {
        CKRecord.ID(recordName: "\(kind.rawValue)-\(uuid)")
    }
}
