import CloudKit
import Foundation
import LexiCore
import os.log

/// iCloud(CloudKit) 동기화 서비스. LexiCore의 SyncStore가 DB 병합을 전담하고,
/// 여기는 CKSyncEngine과 CloudKit 사이의 전송만 맡는다.
///
/// 흐름:
/// - 푸시: 3초 폴링으로 미전송 저널을 배치에 싣는다. 설정 화면의 "지금 동기화"도 같은 경로.
/// - 풀: 엔진이 변경을 가져오면 스냅샷으로 바꿔 SyncStore.applyRemote로 적용하고,
///   내용이 바뀌면 `.lexiLibraryChanged`를 보내 화면을 새로 고친다.
/// - 충돌: concept은 updatedAt 기준 last-writer-wins(판정은 SyncStore가 한다),
///   개정본·출처는 append-only, 삭제는 묘비로 수렴시킨다.
@MainActor
final class CloudSyncService: NSObject, ObservableObject {
    static let containerIdentifier = "iCloud.kr.garden.lexi.app"
    static let zoneName = "LexiZone"
    static let storageKey = "iCloudSyncEnabled"

    /// 설정 화면에 보여줄 동기화 상태.
    enum Phase: Equatable {
        case off
        case starting
        case waitingForAccount
        case syncing
        case upToDate(lastChangedAt: Date?)
        case failed(String)

        var label: String {
            switch self {
            case .off: String(localized: "꺼짐")
            case .starting: String(localized: "준비 중…")
            case .waitingForAccount: String(localized: "iCloud 계정을 기다리는 중")
            case .syncing: String(localized: "동기화 중…")
            case .upToDate: String(localized: "최신 상태예요")
            case .failed(let message): String(localized: "문제가 있어요: \(message)")
            }
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var pendingCount = 0

    private var engine: CKSyncEngine?
    private var store: SyncStore?
    private var pollTask: Task<Void, Never>?
    private var zoneEnqueued = false
    private let log = Logger(subsystem: "kr.garden.lexi.app", category: "sync")

    var isEnabled: Bool { engine != nil }

    /// 설정 토글이 부르는 진입점.
    func setEnabled(_ enabled: Bool) async {
        if enabled {
            await start()
        } else {
            stop()
        }
    }

    func start() async {
        guard engine == nil else { return }
        // iCloud 권한이 서명에 없거나(미서명 개발 빌드) 계정이 꺼진 환경에서는
        // CKContainer 생성 전에 대기 상태로 둔다. CKContainer 예외는 Swift try로
        // 잡히지 않으므로 미리 걸러낸다.
        guard FileManager.default.ubiquityIdentityToken != nil else {
            phase = .waitingForAccount
            return
        }
        phase = .starting
        do {
            let db = try await Task.detached(priority: .userInitiated) { [log] in
                let db = try AppDatabase.makeDefault()
                try db.migrate()
                return db
            }.value
            let store = SyncStore(database: db)
            self.store = store

            let configuration = CKSyncEngine.Configuration(
                database: CKContainer(identifier: Self.containerIdentifier).privateCloudDatabase,
                stateSerialization: Self.loadStateSerialization(),
                delegate: self
            )
            let engine = CKSyncEngine(configuration)
            self.engine = engine

            let status = try? await CKContainer(identifier: Self.containerIdentifier)
                .accountStatus()
            if status != .available {
                // 계정이 붙으면 엔진이 accountChange 이벤트로 깨워준다.
                phase = .waitingForAccount
            }
            pollTask = Task { [weak self] in await self?.pollLoop() }
            await initialUploadIfNeeded()
        } catch {
            log.error("동기화 시작 실패: \(String(describing: error))")
            phase = .failed(String(localized: "시작에 실패했어요"))
            stop()
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        engine = nil
        store = nil
        zoneEnqueued = false
        pendingCount = 0
        phase = .off
    }

    /// 설정 화면의 "지금 동기화". 밀어 올릴 것을 싣고 원격 변경도 즉시 가져온다.
    func syncNow() async {
        guard engine != nil else { return }
        await enqueueAndSend()
        try? await engine?.fetchChanges()
    }

    // MARK: - 푸시

    private func initialUploadIfNeeded() async {
        guard let store, let engine else { return }
        guard (try? await store.needsInitialUpload()) == true else { return }
        log.info("동기화 최초 설정: 기존 사전 전체를 올린다")
        do {
            let records = try await store.allRecords()
            enqueueZoneIfNeeded(engine)
            engine.state.add(pendingRecordZoneChanges: records.map { .saveRecord($0.cloudRecordID) })
            phase = .syncing
            try await engine.sendChanges()
            try await store.markInitialUploadDone()
            phase = .upToDate(lastChangedAt: Date())
        } catch {
            // 계정이 없거나 네트워크가 없으면 다음 사이클이 다시 시도한다.
            log.error("최초 업로드 실패: \(String(describing: error))")
            phase = .failed(String(localized: "업로드에 실패했어요"))
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard let store, engine != nil else { return }
            let count = (try? await store.database.pendingSyncCount()) ?? 0
            pendingCount = count
            guard count > 0 else { continue }
            await enqueueAndSend()
        }
    }

    private func enqueueAndSend() async {
        guard let store, let engine else { return }
        guard let push = try? await store.pendingPush(limit: 250), !push.isEmpty else { return }
        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        pending += push.upserts.map { .saveRecord($0.cloudRecordID) }
        pending += push.deletes.map { .deleteRecord($0.cloudRecordID) }
        enqueueZoneIfNeeded(engine)
        engine.state.add(pendingRecordZoneChanges: pending)
        phase = .syncing
        try? await engine.sendChanges()
    }

    private func enqueueZoneIfNeeded(_ engine: CKSyncEngine) {
        guard !zoneEnqueued else { return }
        zoneEnqueued = true
        engine.state.add(pendingDatabaseChanges: [
            .saveZone(CKRecordZone(zoneName: Self.zoneName))
        ])
    }

    /// 엔진의 위임 콜백(handleEvent) 안에서 엔진 메서드를 await하면 CloudKit이
    /// 콜백 직렬성을 보장할 수 없어 fatal error로 앱을 종료한다. detached Task는
    /// 콜백의 작업 컨텍스트를 상속하지 않으므로 콜백에서 시작한 엔진 호출은
    /// 이쪽으로 넘겨 이어 실행한다.
    private func continueOutsideDelegateCallback(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        Task.detached(priority: .userInitiated) {
            await operation()
        }
    }

    /// 콜백 밖 컨텍스트에서 대기 중 변경을 서버로 올린다.
    private func sendPendingChanges() async {
        guard let engine else { return }
        try? await engine.sendChanges()
    }

    // MARK: - 상태 직렬화

    private static func stateURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lexi", isDirectory: true)
            .appendingPathComponent("sync-engine-state.json")
    }

    private static func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: stateURL()) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private static func persistStateSerialization(_ serialization: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(serialization) else { return }
        try? data.write(to: stateURL(), options: .atomic)
    }

    // MARK: - 이벤트 처리(엔진에서 온다)

    private func handleEvent(_ event: CKSyncEngine.Event) async {
        switch event {
        case .stateUpdate(let event):
            Self.persistStateSerialization(event.stateSerialization)

        case .accountChange(let event):
            switch event.changeType {
            case .signIn:
                // 로컬 SQLite가 정본이므로 데이터는 그대로 두고, 필요하면 전체를 올린다.
                // 위임 콜백 안에서 엔진을 기다릴 수는 없어 detached Task로 넘긴다.
                continueOutsideDelegateCallback {
                    await self.initialUploadIfNeeded()
                    self.phase = .upToDate(lastChangedAt: nil)
                }
            case .signOut, .switchAccounts:
                phase = .waitingForAccount
            @unknown default:
                break
            }

        case .fetchedRecordZoneChanges(let event):
            await applyFetched(event)

        case .sentRecordZoneChanges(let event):
            await handleSent(event)

        case .willSendChanges, .willFetchChanges, .willFetchRecordZoneChanges:
            if phase != .waitingForAccount { phase = .syncing }

        case .didSendChanges, .didFetchChanges, .didFetchRecordZoneChanges:
            if phase == .syncing { phase = .upToDate(lastChangedAt: Date()) }

        case .fetchedDatabaseChanges, .sentDatabaseChanges:
            break

        default:
            break
        }
    }

    /// 원격에서 가져온 레코드를 정본 DB에 적용한다.
    private func applyFetched(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
        guard let store else { return }
        var upserts: [SyncRecord] = []
        var deletions: [SyncRecordRef] = []
        for modification in event.modifications {
            if let snapshot = SyncRecord(cloudRecord: modification.record) {
                upserts.append(snapshot)
            }
        }
        for deletion in event.deletions {
            if let ref = SyncRecordRef(cloudRecordID: deletion.recordID) {
                deletions.append(ref)
            }
        }
        guard !upserts.isEmpty || !deletions.isEmpty else { return }
        do {
            let report = try await store.applyRemote(upserts: upserts, deletions: deletions)
            log.info("원격 변경 적용: 반영 \(report.appliedUpserts) 삭제 \(report.appliedDeletes) 보관 \(report.stashed)")
            if report.appliedUpserts > 0 || report.appliedDeletes > 0 {
                NotificationCenter.default.post(name: .lexiLibraryChanged, object: nil)
            }
        } catch {
            log.error("원격 변경 적용 실패: \(String(describing: error))")
            phase = .failed(String(localized: "원격 변경을 적용하지 못했어요"))
        }
    }

    /// 전송 결과를 정리한다: 성공은 저널에서 지우고, 실패는 원인별로 수렴시킨다.
    private func handleSent(_ event: CKSyncEngine.Event.SentRecordZoneChanges) async {
        guard let store, let engine else { return }
        let savedRefs = event.savedRecords.compactMap { SyncRecord(cloudRecord: $0) }
            .map { SyncRecordRef(kind: $0.kind, uuid: $0.uuid) }
        if !savedRefs.isEmpty {
            try? await store.acknowledgeUpserts(savedRefs)
        }
        let deletedRefs = event.deletedRecordIDs.compactMap(SyncRecordRef.init(cloudRecordID:))
        if !deletedRefs.isEmpty {
            try? await store.acknowledgeDeletes(deletedRefs)
        }

        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        for failed in event.failedRecordSaves {
            switch failed.error.code {
            case .serverRecordChanged:
                // 충돌: 로컬과 서버 중 누가 이겼는지는 updatedAt으로 판정한다.
                guard let ref = SyncRecordRef(cloudRecordID: failed.record.recordID),
                      let serverRecord = failed.error.serverRecord
                else { continue }
                let local = try? await store.recordSnapshot(kind: ref.kind, uuid: ref.uuid)
                if let local,
                   (local.updatedAt ?? .distantPast)
                       > (serverRecord["updatedAt"] as? Date ?? .distantPast) {
                    // 로컬 승리: 서버 레코드 위에 로컬 값을 얹어 다시 올린다(changeTag 유지).
                    local.apply(to: serverRecord)
                    retry.append(.saveRecord(serverRecord.recordID))
                } else if let serverSnapshot = SyncRecord(cloudRecord: serverRecord) {
                    // 서버 승리: 서버 내용을 로컬에 적용하고 미전송 표시를 비운다.
                    _ = try? await store.applyRemote(upserts: [serverSnapshot], deletions: [])
                    try? await store.acknowledgeUpserts([ref])
                }
            case .zoneNotFound:
                enqueueZoneIfNeeded(engine)
                retry.append(.saveRecord(failed.record.recordID))
            case .unknownItem:
                // 다른 기기가 지운 레코드를 우리가 다시 만든 경우. 다시 올려 수렴시킨다.
                retry.append(.saveRecord(failed.record.recordID))
            default:
                break  // 엔진이 자동 재시도하는 일시 오류
            }
        }
        for (recordID, error) in event.failedRecordDeletes {
            switch error.code {
            case .unknownItem:
                // 이미 서버에 없다. 묘비는 목적을 달성했다.
                if let ref = SyncRecordRef(cloudRecordID: recordID) {
                    try? await store.acknowledgeDeletes([ref])
                }
            case .zoneNotFound:
                enqueueZoneIfNeeded(engine)
                retry.append(.deleteRecord(recordID))
            default:
                break
            }
        }
        if !retry.isEmpty {
            engine.state.add(pendingRecordZoneChanges: retry)
            continueOutsideDelegateCallback { await self.sendPendingChanges() }
        }
    }
}

extension CloudSyncService: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await handleEvent(event)
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        let store = self.store
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            guard case .saveRecord = recordNameChange(recordID, in: changes) else { return nil }
            guard let name = SyncRecordRef(cloudRecordID: recordID),
                  let snapshot = try? await store?.recordSnapshot(
                      kind: name.kind, uuid: name.uuid)
            else { return nil }
            return snapshot.makeCKRecord()
        }
    }
}

/// 배치 제공자가 save인지 delete인지 판별한다. delete는 레코드 없이도 처리된다.
private func recordNameChange(
    _ recordID: CKRecord.ID, in changes: [CKSyncEngine.PendingRecordZoneChange]
) -> CKSyncEngine.PendingRecordZoneChange? {
    for change in changes {
        switch change {
        case .saveRecord(let id) where id == recordID: return change
        case .deleteRecord(let id) where id == recordID: return change
        default: continue
        }
    }
    return nil
}
