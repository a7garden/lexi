import Foundation
import GRDB

/// DB 정본 ↔ 동기화 레코드 사이의 순수 상태 기계. 계정·네트워크에 의존하지 않아
/// 전부 단위 테스트 가능하다. CloudKit 전송은 앱 계층(CloudSyncService)이 맡는다.
///
/// 병합 규칙:
/// - concept 필드는 updatedAt 기준 last-writer-wins. 같으면 로컬 유지.
/// - definitionRevision·sourceRef는 append-only. 같은 uuid가 이미 있으면 로컬을
///   덮지 않고 무시한다(provenance 보존).
/// - alias는 uuid 기준 insert-only. (concept, text, lang)이 같은 다른 uuid 행이
///   이미 있으면 그 원격 행은 패배로 보고 묘비를 남겨 서버를 수렴시킨다.
/// - 부모보다 자식이 먼저 도착하면 syncPendingRemote에 JSON으로 보관하고, 부모가
///   도착하거나 명시 호출 때 재적용한다.
/// - lookupRecord는 행동 기록이라 동기화하지 않는다(PDC 정본 규칙과 같은 판단).
public struct SyncStore: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - 최초 전체 업로드

    /// 동기화를 처음 켜면 저널이 비어 있어도 기존 데이터 전체를 올려야 한다.
    public func needsInitialUpload() async throws -> Bool {
        try await database.writer.read { db in
            try String.fetchOne(
                db, sql: "SELECT value FROM syncMeta WHERE key = 'initialUploadDone'"
            ) == nil
        }
    }

    public func markInitialUploadDone() async throws {
        _ = try await database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO syncMeta (key, value) VALUES ('initialUploadDone', '1') ON CONFLICT(key) DO NOTHING"
            )
        }
    }

    /// 최초 업로드용 전체 스냅샷. 부모 → 자식 순서다.
    public func allRecords() async throws -> [SyncRecord] {
        try await database.writer.read { db in
            var records: [SyncRecord] = []
            for kind in [SyncKind.concept, .revision, .alias, .source] {
                let uuids = try String.fetchAll(
                    db, sql: "SELECT uuid FROM \(kind.tableName) WHERE uuid IS NOT NULL ORDER BY id"
                )
                for uuid in uuids {
                    if let record = try Self.snapshot(kind: kind, uuid: uuid, in: db) {
                        records.append(record)
                    }
                }
            }
            return records
        }
    }

    // MARK: - 푸시 수집

    /// 저널에서 수집한 미전송 변경.
    public struct PendingPush: Sendable, Equatable {
        public var upserts: [SyncRecord] = []
        public var deletes: [SyncRecordRef] = []

        public var isEmpty: Bool { upserts.isEmpty && deletes.isEmpty }

        public init() {}
    }

    /// 미전송 변경을 푸시용 스냅샷으로 모은다. upsert는 현재 행 값을 읽는다.
    /// 저널이 가리키는 행이 이미 없으면(비정상) 그 항목은 건너뛴다.
    public func pendingPush(limit: Int = 500) async throws -> PendingPush {
        try await database.writer.read { db in
            var push = PendingPush()
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT uuid, kind, op FROM syncJournal ORDER BY changedAt, id LIMIT ?",
                arguments: [limit]
            )
            for row in rows {
                let rawKind: String = row["kind"]
                let rawUUID: String = row["uuid"]
                let rawOp: String = row["op"]
                guard let kind = SyncKind(rawValue: rawKind) else { continue }
                if rawOp == SyncOperation.delete.rawValue {
                    push.deletes.append(SyncRecordRef(kind: kind, uuid: rawUUID))
                } else if let record = try Self.snapshot(kind: kind, uuid: rawUUID, in: db) {
                    push.upserts.append(record)
                }
            }
            return push
        }
    }

    /// CloudKit 저장이 성공한 upsert 항목의 저널을 비운다.
    public func acknowledgeUpserts(_ refs: [SyncRecordRef]) async throws {
        guard !refs.isEmpty else { return }
        _ = try await database.writer.write { db in
            for ref in refs {
                try SyncJournal.acknowledge(db, kind: ref.kind, uuids: [ref.uuid], operation: .upsert)
            }
        }
    }

    /// CloudKit 삭제가 성공한 묘비의 저널을 비운다.
    public func acknowledgeDeletes(_ refs: [SyncRecordRef]) async throws {
        guard !refs.isEmpty else { return }
        _ = try await database.writer.write { db in
            for ref in refs {
                try SyncJournal.acknowledge(db, kind: ref.kind, uuids: [ref.uuid], operation: .delete)
            }
        }
    }

    // MARK: - 원격 적용

    public struct ApplyReport: Sendable, Equatable {
        public var appliedUpserts = 0
        public var appliedDeletes = 0
        /// 부모 미도착으로 보관함에 들어간(또는 대기 중인) 항목 수.
        public var stashed = 0
        /// 규칙상 무시한 항목 수(개정본 재도착, 늦은 concept 등).
        public var ignored = 0
        /// 서버 수렴을 위해 묘비를 남긴 항목 수(중복 alias 등).
        public var convergenceDeletes = 0

        public init() {}
    }

    /// 원격 변경을 하나의 트랜잭션으로 적용한다. 의존 순서(concept → revision →
    /// alias → source)로 정렬해 적용하고, 부모가 있는 자식이 다 적용되면 보관함을
    /// 다시 시도한다.
    public func applyRemote(
        upserts: [SyncRecord], deletions: [SyncRecordRef]
    ) async throws -> ApplyReport {
        try await database.writer.write { db in
            var report = ApplyReport()
            for kind in [SyncKind.concept, .revision, .alias, .source] {
                for record in upserts where record.kind == kind {
                    try Self.applyUpsert(record, in: db, into: &report)
                }
            }
            for deletion in deletions {
                try Self.applyDeletion(deletion, in: db, into: &report)
            }
            if report.appliedUpserts > 0 {
                try Self.applyStashed(in: db, into: &report)
            }
            return report
        }
    }

    /// 보관함에 밀린 원격 변경을 다시 적용 시도한다. 부모가 계속 없으면 보관된다.
    public func applyStashed() async throws -> ApplyReport {
        try await database.writer.write { db in
            var report = ApplyReport()
            try Self.applyStashed(in: db, into: &report)
            return report
        }
    }

    // MARK: - 행 스냅샷

    /// 한 행의 현재 값을 스냅샷으로 읽는다. 행이 없으면 nil.
    static func snapshot(kind: SyncKind, uuid: String, in db: Database) throws -> SyncRecord? {
        switch kind {
        case .concept:
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT preferredTerm, field, isFavorite, lang, createdAt, updatedAt
                FROM concept WHERE uuid = ?
                """,
                arguments: [uuid]
            ) else { return nil }
            let text: String = row["preferredTerm"]
            return SyncRecord(
                kind: .concept, uuid: uuid,
                preferredTerm: text,
                field: row["field"] as String?,
                isFavorite: row["isFavorite"] as Bool?,
                lang: row["lang"] as String?,
                createdAt: row["createdAt"] as Date?,
                updatedAt: row["updatedAt"] as Date?
            )
        case .revision:
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT d.oneLine, d.easyExplanation, d.author, d.provider, d.lang, d.createdAt,
                       c.uuid AS parentUUID
                FROM definitionRevision d JOIN concept c ON c.id = d.conceptId
                WHERE d.uuid = ?
                """,
                arguments: [uuid]
            ) else { return nil }
            return SyncRecord(
                kind: .revision, uuid: uuid, parentUUID: row["parentUUID"] as String?,
                lang: row["lang"] as String?,
                createdAt: row["createdAt"] as Date?,
                oneLine: row["oneLine"] as String?,
                easyExplanation: row["easyExplanation"] as String?,
                author: row["author"] as String?,
                provider: row["provider"] as String?
            )
        case .alias:
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT a.text, a.lang, c.uuid AS parentUUID
                FROM alias a JOIN concept c ON c.id = a.conceptId
                WHERE a.uuid = ?
                """,
                arguments: [uuid]
            ) else { return nil }
            return SyncRecord(
                kind: .alias, uuid: uuid, parentUUID: row["parentUUID"] as String?,
                lang: row["lang"] as String?,
                text: row["text"] as String?
            )
        case .source:
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT s.title, s.url, s.excerpt, s.retrievedAt, d.uuid AS parentUUID
                FROM sourceRef s JOIN definitionRevision d ON d.id = s.revisionId
                WHERE s.uuid = ?
                """,
                arguments: [uuid]
            ) else { return nil }
            return SyncRecord(
                kind: .source, uuid: uuid, parentUUID: row["parentUUID"] as String?,
                title: row["title"] as String?,
                url: row["url"] as String?,
                excerpt: row["excerpt"] as String?,
                retrievedAt: row["retrievedAt"] as Date?
            )
        }
    }

    // MARK: - 적용 내부

    static func applyUpsert(
        _ record: SyncRecord, in db: Database, into report: inout ApplyReport, allowStash: Bool = true
    ) throws {
        switch record.kind {
        case .concept:
            try applyConcept(record, in: db, into: &report)
        case .revision:
            try applyRevision(record, in: db, into: &report, allowStash: allowStash)
        case .alias:
            try applyAlias(record, in: db, into: &report, allowStash: allowStash)
        case .source:
            try applySource(record, in: db, into: &report, allowStash: allowStash)
        }
    }

    static func applyConcept(
        _ record: SyncRecord, in db: Database, into report: inout ApplyReport
    ) throws {
        if let localId = try Int64.fetchOne(
            db, sql: "SELECT id FROM concept WHERE uuid = ?", arguments: [record.uuid]
        ) {
            let localUpdatedAt = try Date.fetchOne(
                db, sql: "SELECT updatedAt FROM concept WHERE id = ?", arguments: [localId])
            let remoteUpdatedAt = record.updatedAt ?? .distantPast
            if let localUpdatedAt, remoteUpdatedAt <= localUpdatedAt {
                report.ignored += 1
                return
            }
            let oldTerm = try String.fetchOne(
                db, sql: "SELECT preferredTerm FROM concept WHERE id = ?", arguments: [localId])
            let newTerm = record.preferredTerm ?? ""
            try db.execute(
                sql: """
                UPDATE concept
                SET preferredTerm = ?, field = ?, isFavorite = ?, lang = ?, updatedAt = ?
                WHERE id = ?
                """,
                arguments: [
                    newTerm, record.field, record.isFavorite ?? false,
                    record.lang, record.updatedAt ?? Date.now, localId,
                ]
            )
            // 표제어가 바뀌면 표제어 alias도 함께 옮긴다. 편집 UI는 없지만 원격 병합에서
            // 바뀐 표제어가 올 수 있고, 조회는 alias를 통하므로 인덱스를 나두면 깨진다.
            if let oldTerm, !newTerm.isEmpty, oldTerm != newTerm,
               try Int64.fetchOne(
                   db, sql: "SELECT 1 FROM alias WHERE conceptId = ? AND text = ?",
                   arguments: [localId, newTerm]) == nil {
                let termAliasUUID = try String.fetchOne(
                    db, sql: "SELECT uuid FROM alias WHERE conceptId = ? AND text = ?",
                    arguments: [localId, oldTerm])
                if let termAliasUUID {
                    try db.execute(
                        sql: "UPDATE alias SET text = ? WHERE uuid = ?",
                        arguments: [newTerm, termAliasUUID])
                    try SyncJournal.upsert(db, kind: .alias, uuid: termAliasUUID)
                }
            }
            // 원격이 이긴 내용은 서버와 같으므로 남아 있는 미전송 표시를 비운다.
            try SyncJournal.acknowledge(db, kind: .concept, uuids: [record.uuid], operation: .upsert)
            report.appliedUpserts += 1
            return
        }
        try db.execute(
            sql: """
            INSERT INTO concept (preferredTerm, field, isFavorite, lang, createdAt, updatedAt, uuid)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                record.preferredTerm ?? "", record.field, record.isFavorite ?? false,
                record.lang, record.createdAt ?? Date.now, record.updatedAt ?? Date.now,
                record.uuid,
            ]
        )
        report.appliedUpserts += 1
    }

    static func applyRevision(
        _ record: SyncRecord, in db: Database, into report: inout ApplyReport, allowStash: Bool
    ) throws {
        if try Int64.fetchOne(
            db, sql: "SELECT 1 FROM definitionRevision WHERE uuid = ?", arguments: [record.uuid]
        ) != nil {
            // 개정본은 불변이다. 같은 uuid 재도착은 무시하고 기존 provenance를 지킨다.
            report.ignored += 1
            return
        }
        guard let conceptId = try conceptId(ofUUID: record.parentUUID, in: db) else {
            if allowStash {
                try stash(record, in: db)
                report.stashed += 1
            }
            return
        }
        try db.execute(
            sql: """
            INSERT INTO definitionRevision
                (conceptId, oneLine, easyExplanation, author, provider, lang, createdAt, uuid)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                conceptId, record.oneLine ?? "", record.easyExplanation ?? "",
                record.author ?? "ai", record.provider, record.lang,
                record.createdAt ?? Date.now, record.uuid,
            ]
        )
        report.appliedUpserts += 1
    }

    static func applyAlias(
        _ record: SyncRecord, in db: Database, into report: inout ApplyReport, allowStash: Bool
    ) throws {
        if try Int64.fetchOne(
            db, sql: "SELECT 1 FROM alias WHERE uuid = ?", arguments: [record.uuid]
        ) != nil {
            report.ignored += 1
            return
        }
        guard let conceptId = try conceptId(ofUUID: record.parentUUID, in: db) else {
            if allowStash {
                try stash(record, in: db)
                report.stashed += 1
            }
            return
        }
        guard let text: String = record.text, !text.isEmpty else {
            report.ignored += 1
            return
        }
        let lang = record.lang ?? "ko"
        if try Int64.fetchOne(
            db,
            sql: "SELECT 1 FROM alias WHERE conceptId = ? AND text = ? AND lang = ?",
            arguments: [conceptId, text, lang]
        ) != nil {
            // 같은 표현을 두 기기가 따로 만든 경우. 이 원격 행은 패배 — 서버에 묘비를
            // 남겨 중복 레코드를 수렴시킨다.
            try SyncJournal.delete(db, kind: .alias, uuid: record.uuid)
            report.convergenceDeletes += 1
            return
        }
        try db.execute(
            sql: "INSERT INTO alias (conceptId, text, lang, uuid) VALUES (?, ?, ?, ?)",
            arguments: [conceptId, text, lang, record.uuid]
        )
        report.appliedUpserts += 1
    }

    static func applySource(
        _ record: SyncRecord, in db: Database, into report: inout ApplyReport, allowStash: Bool
    ) throws {
        if try Int64.fetchOne(
            db, sql: "SELECT 1 FROM sourceRef WHERE uuid = ?", arguments: [record.uuid]
        ) != nil {
            report.ignored += 1
            return
        }
        guard let revisionId = try revisionId(ofUUID: record.parentUUID, in: db) else {
            if allowStash {
                try stash(record, in: db)
                report.stashed += 1
            }
            return
        }
        try db.execute(
            sql: """
            INSERT INTO sourceRef (revisionId, title, url, excerpt, retrievedAt, uuid)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                revisionId, record.title ?? "", record.url, record.excerpt,
                record.retrievedAt ?? Date.now, record.uuid,
            ]
        )
        report.appliedUpserts += 1
    }

    static func applyDeletion(
        _ ref: SyncRecordRef, in db: Database, into report: inout ApplyReport
    ) throws {
        switch ref.kind {
        case .concept:
            try deleteConcept(uuid: ref.uuid, in: db)
        case .revision:
            try deleteRevision(uuid: ref.uuid, in: db)
        case .alias:
            try db.execute(sql: "DELETE FROM alias WHERE uuid = ?", arguments: [ref.uuid])
        case .source:
            try db.execute(sql: "DELETE FROM sourceRef WHERE uuid = ?", arguments: [ref.uuid])
        }
        // 원격 삭제가 최종 상태다. 이 행의 미전송 표시는 무의미해진다.
        try SyncJournal.acknowledgeAll(db, kind: ref.kind, uuids: [ref.uuid])
        report.appliedDeletes += 1
    }

    /// 원격 concept 삭제. 자식도 함께 사라지므로 자식 저널도 정리한다.
    static func deleteConcept(uuid: String, in db: Database) throws {
        guard let id = try Int64.fetchOne(
            db, sql: "SELECT id FROM concept WHERE uuid = ?", arguments: [uuid]
        ) else { return }
        let aliasUUIDs = try String.fetchAll(
            db, sql: "SELECT uuid FROM alias WHERE conceptId = ? AND uuid IS NOT NULL",
            arguments: [id])
        let revisionRows = try Row.fetchAll(
            db, sql: "SELECT id, uuid FROM definitionRevision WHERE conceptId = ?",
            arguments: [id])
        let revisionIds = revisionRows.map { $0["id"] as Int64 }
        let revisionUUIDs = revisionRows.compactMap { $0["uuid"] as String? }
        var sourceUUIDs: [String] = []
        if !revisionIds.isEmpty {
            let placeholders = String(repeating: "?,", count: revisionIds.count).dropLast()
            sourceUUIDs = try String.fetchAll(
                db,
                sql: "SELECT uuid FROM sourceRef WHERE revisionId IN (\(placeholders)) AND uuid IS NOT NULL",
                arguments: StatementArguments(revisionIds)
            )
        }
        try db.execute(sql: "DELETE FROM concept WHERE id = ?", arguments: [id])
        try SyncJournal.acknowledgeAll(db, kind: .alias, uuids: aliasUUIDs)
        try SyncJournal.acknowledgeAll(db, kind: .revision, uuids: revisionUUIDs)
        try SyncJournal.acknowledgeAll(db, kind: .source, uuids: sourceUUIDs)
    }

    /// 원격 revision 삭제. 출처도 cascade로 사라지므로 저널을 함께 정리한다.
    static func deleteRevision(uuid: String, in db: Database) throws {
        guard let id = try Int64.fetchOne(
            db, sql: "SELECT id FROM definitionRevision WHERE uuid = ?", arguments: [uuid]
        ) else { return }
        let sourceUUIDs = try String.fetchAll(
            db, sql: "SELECT uuid FROM sourceRef WHERE revisionId = ? AND uuid IS NOT NULL",
            arguments: [id])
        try db.execute(sql: "DELETE FROM definitionRevision WHERE id = ?", arguments: [id])
        try SyncJournal.acknowledgeAll(db, kind: .source, uuids: sourceUUIDs)
    }

    static func applyStashed(in db: Database, into report: inout ApplyReport) throws {
        let rows = try Row.fetchAll(
            db, sql: "SELECT uuid, kind, payload FROM syncPendingRemote ORDER BY id")
        guard !rows.isEmpty else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for row in rows {
            let storedUUID: String = row["uuid"]
            let storedKind: String = row["kind"]
            let payload: String = row["payload"]
            guard let data = payload.data(using: .utf8),
                  let record = try? decoder.decode(SyncRecord.self, from: data)
            else {
                // 깨진 보관 항목은 판독 불가이므로 버린다.
                try db.execute(
                    sql: "DELETE FROM syncPendingRemote WHERE uuid = ? AND kind = ?",
                    arguments: [storedUUID, storedKind])
                continue
            }
            var stashReport = ApplyReport()
            try applyUpsert(record, in: db, into: &stashReport, allowStash: false)
            if stashReport.stashed == 0 {
                try db.execute(
                    sql: "DELETE FROM syncPendingRemote WHERE uuid = ? AND kind = ?",
                    arguments: [storedUUID, storedKind])
            }
            report.appliedUpserts += stashReport.appliedUpserts
            report.ignored += stashReport.ignored
            report.convergenceDeletes += stashReport.convergenceDeletes
            if stashReport.stashed > 0 {
                report.stashed += 1
            }
        }
    }

    /// 부모 미도착 변경을 JSON으로 보관한다. 같은 행이 다시 오면 최신 payload로 덮는다.
    static func stash(_ record: SyncRecord, in db: Database) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try db.execute(
            sql: """
            INSERT INTO syncPendingRemote (uuid, kind, payload, createdAt) VALUES (?, ?, ?, ?)
            ON CONFLICT(uuid, kind) DO UPDATE
            SET payload = excluded.payload, createdAt = excluded.createdAt
            """,
            arguments: [
                record.uuid, record.kind.rawValue,
                String(data: data, encoding: .utf8) ?? "", Date.now,
            ]
        )
    }

    static func conceptId(ofUUID uuid: String?, in db: Database) throws -> Int64? {
        guard let uuid else { return nil }
        return try Int64.fetchOne(
            db, sql: "SELECT id FROM concept WHERE uuid = ?", arguments: [uuid])
    }

    static func revisionId(ofUUID uuid: String?, in db: Database) throws -> Int64? {
        guard let uuid else { return nil }
        return try Int64.fetchOne(
            db, sql: "SELECT id FROM definitionRevision WHERE uuid = ?", arguments: [uuid])
    }
}

extension SyncKind {
    /// 동기화 테이블 이름. kind 값과 우연히 같지 않고 규약으로 고정한다.
    var tableName: String {
        switch self {
        case .concept: return "concept"
        case .revision: return "definitionRevision"
        case .alias: return "alias"
        case .source: return "sourceRef"
        }
    }
}

public extension SyncStore {
    /// 한 행의 현재 스냅샷. 전송 배치(recordProvider)와 충돌 해결이 읽는다.
    func recordSnapshot(kind: SyncKind, uuid: String) async throws -> SyncRecord? {
        try await database.writer.read { db in
            try Self.snapshot(kind: kind, uuid: uuid, in: db)
        }
    }
}
