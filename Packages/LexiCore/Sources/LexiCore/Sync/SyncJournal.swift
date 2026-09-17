import Foundation
import GRDB

/// 동기화 대상 종류. CloudKit 레코드 타입 이름으로도 쓴다.
public enum SyncKind: String, Sendable, Codable, CaseIterable {
    case concept
    case revision
    case alias
    case source
}

/// 저널에 기록하는 변경 종류.
public enum SyncOperation: String, Sendable, Codable {
    case upsert
    case delete
}

/// 내용 쓰기와 같은 트랜잭션 안에서 미전송 변경을 기록하는 저널.
///
/// 규칙:
/// - 반드시 내용 쓰기와 같은 `writer.write` 클로저 안에서 호출한다. 그래야 내용과
///   저널이 함께 원자적으로 반영된다(저널만 남거나 내용만 바뀌는 상태가 없다).
/// - (uuid, kind)마다 행 하나만 유지하고 최신 op로 덮어쓴다. CloudKit으로 ack되면
///   행을 지운다. 동기화를 끈 기간의 변경도 남아 있다가, 다시 켜면 전부 밀어 올린다.
enum SyncJournal {
    /// 새 값 또는 갱신을 미전송으로 표시한다.
    static func upsert(_ db: Database, kind: SyncKind, uuid: String) throws {
        try db.execute(
            sql: """
            INSERT INTO syncJournal (uuid, kind, op, changedAt) VALUES (?, ?, 'upsert', ?)
            ON CONFLICT(uuid, kind) DO UPDATE SET op = 'upsert', changedAt = excluded.changedAt
            """,
            arguments: [uuid, kind.rawValue, Date.now]
        )
    }

    /// 삭제를 미전송으로 표시한다(묘비).
    static func delete(_ db: Database, kind: SyncKind, uuid: String) throws {
        try db.execute(
            sql: """
            INSERT INTO syncJournal (uuid, kind, op, changedAt) VALUES (?, ?, 'delete', ?)
            ON CONFLICT(uuid, kind) DO UPDATE SET op = 'delete', changedAt = excluded.changedAt
            """,
            arguments: [uuid, kind.rawValue, Date.now]
        )
    }

    /// CloudKit에 성공히 반영된 항목은 저널에서 지운다.
    static func acknowledge(
        _ db: Database, kind: SyncKind, uuids: [String], operation: SyncOperation
    ) throws {
        guard !uuids.isEmpty else { return }
        let placeholders = String(repeating: "?,", count: uuids.count).dropLast()
        try db.execute(
            sql: """
            DELETE FROM syncJournal
            WHERE kind = ? AND op = ? AND uuid IN (\(placeholders))
            """,
            arguments: StatementArguments([kind.rawValue, operation.rawValue] + uuids)
        )
    }

    /// op와 무관하게 저널 항목을 정리한다. 원격 삭제가 최종 상태일 때 쓴다.
    static func acknowledgeAll(_ db: Database, kind: SyncKind, uuids: [String]) throws {
        guard !uuids.isEmpty else { return }
        let placeholders = String(repeating: "?,", count: uuids.count).dropLast()
        try db.execute(
            sql: "DELETE FROM syncJournal WHERE kind = ? AND uuid IN (\(placeholders))",
            arguments: StatementArguments([kind.rawValue] + uuids)
        )
    }
}

extension AppDatabase {
    /// 아직 CloudKit에 반영되지 않은 저널 항목 수. 동기화 상태 표시에 쓴다.
    public func pendingSyncCount() async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncJournal") ?? 0
        }
    }
}
