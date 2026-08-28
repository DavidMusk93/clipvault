import Foundation
import CryptoKit

/// Multi-device **eventual consistency** over iCloud Drive (cloud transport + per-host txs).
///
/// ## Two planes (do not conflate)
/// - **Backup** (`CloudDocsBackupService`): per-host disaster snapshot. Never a sync bus.
/// - **Live** (this type): append-only transactions per host; attachments next to the log.
///
/// ```
/// …/CloudDocs/ClipFlow/sync/v1/
///   trx/{host_id}/{seq:016d}.json     # transactions (write here)
///   ops/{host_id}/{seq:016d}.json     # legacy, read-only fallback
///   heads/{host_id}.json
/// …/CloudDocs/ClipFlow/live/attach/{key}.bin
/// ```
///
/// Local: outbox under `KEEPSAKE_HOME/sync/outbox/`, cursors in `keepsake_meta`.
final class CloudDocsSyncService {
    private(set) static var shared: CloudDocsSyncService?

    static let statusChangedNotification = Notification.Name("ClipFlowSyncStatusChanged")

    @discardableResult
    static func bootstrap(database: DatabaseManager) -> CloudDocsSyncService {
        if let s = shared { return s }
        let s = CloudDocsSyncService(database: database)
        shared = s
        return s
    }

    // MARK: Types

    struct Config: Codable, Equatable {
        var enabled: Bool = true
        /// Poll remote heads / drain outbox (CloudDocs File Provider is laggy).
        var pollIntervalSeconds: Double = 45
        /// Max ops to pull per host per cycle.
        var pullBatchLimit: Int = 200
        static let `default` = Config()
    }

    struct SyncOp: Codable, Equatable {
        var v: Int = 1
        var opId: String
        var host: String
        var seq: Int
        /// `upsert` | `tombstone` | `touch` | `user_evaluation` | `pin` | `unpin` | `web_archive` | `reader_op` | `compose` | `clip_link`
        var kind: String
        var itemId: String
        var contentHash: String?
        var type: String?
        var wallTs: Double
        var hlc: String
        var textContent: String?
        var htmlContent: String?
        var ocrText: String?
        var sourceApp: String?
        var url: String?
        var fileUrls: [String]?
        var copyCount: Int?
        /// CAS keys under backup/blobs (without `.bin` suffix in storage path — keys as DatabaseManager uses).
        var blobKeys: [String]?
        var note: String?
        /// User judgment layer (kind == user_context); never mutates capture payload.
        var userNote: String?
        var userStage: String?
        var userRating: Double?

        enum CodingKeys: String, CodingKey {
            case v, opId = "op_id", host, seq, kind
            case itemId = "item_id", contentHash = "content_hash", type
            case wallTs = "wall_ts", hlc
            case textContent = "text_content", htmlContent = "html_content"
            case ocrText = "ocr_text", sourceApp = "source_app", url
            case fileUrls = "file_urls", copyCount = "copy_count"
            case blobKeys = "blob_keys", note
            case userNote = "user_note", userStage = "user_stage", userRating = "user_rating"
        }
    }

    struct HostHead: Codable, Equatable {
        var host: String
        var seq: Int
        var lastOpId: String?
        var wallTs: Double
        var itemHint: Int?
        var updatedAt: String
    }

    struct PeerStatus: Codable, Equatable {
        var host: String
        var remoteSeq: Int
        var appliedSeq: Int
        var lag: Int
    }

    struct Status: Codable, Equatable {
        var enabled: Bool
        var hostId: String
        var localSeq: Int
        var outboxPending: Int
        var cloudDocsAvailable: Bool
        var syncRootPath: String?
        /// Canonical transaction directory: `…/sync/v1/trx/{hostId}`
        var trxPath: String? = nil
        var lastPushAt: String?
        var lastPullAt: String?
        var lastPushUnix: Double? = nil
        var lastPullUnix: Double? = nil
        var lastPhase: String?
        var lastError: String?
        var inProgress: Bool
        var peers: [PeerStatus]
        var pollIntervalSeconds: Double
        var scheme: String = "tx+cloud"
        var policy: String
    }

    // MARK: State

    private let database: DatabaseManager
    private let queue = DispatchQueue(label: "com.keepsake.sync.clouddocs", qos: .utility)
    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    private var config: Config
    private let hostId: String
    private var nextSeq: Int = 1
    private var lastPushUnix: Double?
    private var lastPullUnix: Double?
    private var lastPhase: String?
    private var lastError: String?
    private var inProgress = false
    private var pollTimer: DispatchSourceTimer?
    private var peerRemoteSeq: [String: Int] = [:]

    private init(database: DatabaseManager) {
        self.database = database
        self.config = Self.loadConfig()
        self.hostId = ClipHostIdentity.id
        // Hydrate seq + start loops off the critical path (CloudDocs may stall).
        queue.async { [weak self] in
            guard let self = self else { return }
            self.database.performSyncWork {
                if let s = self.database.metaGetSync("sync.next_seq"), let n = Int(s), n > 0 {
                    self.nextSeq = n
                } else {
                    self.nextSeq = max(1, self.highestLocalOutboxSeq() + 1)
                    self.database.metaSetSync("sync.next_seq", String(self.nextSeq))
                }
            }
            self.bootstrapLocalHistoryIfNeeded()
            self.replayDiskReaderOps()
            self.replayDiskClipLinks()
            self.repairArchiveClosures()
            self.startPollTimer()
            if self.config.enabled {
                self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.cycle(reason: "startup")
                }
            }
            self.publishStatus()
            print("[Sync] ready · host=\(self.hostId) · enabled=\(self.config.enabled) · poll=\(Int(self.config.pollIntervalSeconds))s · root=\(self.syncRootURL()?.path ?? "nil")")
        }
    }

    // MARK: Public API

    func recordLocalCapture(item: ClipboardItem, result: DatabaseManager.ItemSaveResult) {
        guard config.enabled else { return }
        guard result != .failed else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            let kind: String
            let itemId: String
            switch result {
            case .failed:
                return
            case .inserted:
                kind = "upsert"
                itemId = item.id.uuidString
            case .bumped(let existingId):
                kind = "touch"
                itemId = existingId.uuidString
            }
            let blobs = self.database.existingBlobKeys(for: item.contentHash)
            // Ensure payload files exist for image/rtf/pdf before op leaves the machine.
            if let data = item.imageData, !data.isEmpty {
                _ = self.database.writeBlobFile(hash: item.contentHash, data: data)
            }
            if let data = item.rtfData, !data.isEmpty {
                _ = self.database.writeBlobFile(hash: item.contentHash + ".rtf", data: data)
            }
            if let data = item.pdfData, !data.isEmpty {
                _ = self.database.writeBlobFile(hash: item.contentHash + ".pdf", data: data)
            }
            let keys = self.database.existingBlobKeys(for: item.contentHash)
            let op = self.makeOp(
                kind: kind,
                itemId: itemId,
                item: item,
                blobKeys: keys.isEmpty ? blobs : keys
            )
            self.enqueue(op)
            self.scheduleDrain(reason: "capture")
        }
    }

    func recordLocalTombstone(id: UUID) {
        guard config.enabled else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            let op = self.makeOp(
                kind: "tombstone",
                itemId: id.uuidString,
                item: nil,
                blobKeys: nil
            )
            self.enqueue(op)
            self.scheduleDrain(reason: "tombstone")
        }
    }

    /// Multi-device fan-out for one evaluation submission (history row). Capture payload stays immutable.
    func recordLocalUserEvaluation(item: ClipboardItem, evaluationId: String, rating: Double?, note: String?) {
        guard config.enabled else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            var op = self.makeOp(
                kind: "user_evaluation",
                itemId: item.id.uuidString,
                item: item,
                blobKeys: nil
            )
            // Use evaluation id as op_id for idempotent peer insert.
            if let eid = UUID(uuidString: evaluationId) {
                op.opId = eid.uuidString
            }
            op.textContent = nil
            op.htmlContent = nil
            op.ocrText = nil
            op.blobKeys = nil
            op.userNote = note ?? item.userNote
            op.userStage = nil
            op.userRating = rating ?? item.userRating
            op.note = "user_evaluation"
            self.enqueue(op)
            self.scheduleDrain(reason: "user_evaluation")
        }
    }

    func recordLocalClipLink(
        opId: String,
        action: String,
        fromId: UUID,
        toContentHash: String?,
        toItemId: String?,
        toIsNote: Bool,
        kind: String,
        pairKey: String,
        ts: Double
    ) {
        guard config.enabled else { return }
        queue.async { [weak self] in
            guard let self else { return }
            var op = self.makeOp(
                kind: "clip_link",
                itemId: fromId.uuidString,
                item: nil,
                blobKeys: nil
            )
            if let eid = UUID(uuidString: opId) {
                op.opId = eid.uuidString
            }
            op.contentHash = toContentHash
            op.wallTs = ts
            var body: [String: Any] = [
                "action": action,
                "kind": kind,
                "to_is_note": toIsNote,
                "pair_key": pairKey,
                "from_item_id": fromId.uuidString,
            ]
            if let toItemId { body["to_item_id"] = toItemId }
            if let toContentHash { body["to_content_hash"] = toContentHash }
            if let data = try? JSONSerialization.data(withJSONObject: body),
               let raw = String(data: data, encoding: .utf8) {
                op.note = raw
            }
            self.enqueue(op)
            self.scheduleDrain(reason: "clip_link")
        }
    }

    func recordLocalPin(itemId: UUID, pinned: Bool, pinnedAt: Date?) {
        guard config.enabled else { return }
        queue.async { [weak self] in
            guard let self else { return }
            var op = self.makeOp(
                kind: pinned ? "pin" : "unpin",
                itemId: itemId.uuidString,
                item: nil,
                blobKeys: nil
            )
            op.wallTs = (pinnedAt ?? Date()).timeIntervalSince1970
            op.note = pinned ? "pin" : "unpin"
            self.enqueue(op)
            self.scheduleDrain(reason: pinned ? "pin" : "unpin")
        }
    }

    func recordLocalArchive(itemId: UUID, htmlSHA: String, metaJSON: String, blobKeys: [String]? = nil) {
        guard config.enabled else { return }
        queue.async { [weak self] in
            self?.enqueueArchive(itemId: itemId, htmlSHA: htmlSHA, metaJSON: metaJSON, blobKeys: blobKeys)
        }
    }

    /// Pull one CAS object into the local store from live/attach or any backup replica.
    @discardableResult
    func hydrateBlob(_ hash: String) -> Bool {
        let hash = hash.lowercased()
        guard ArchiveImageInliner.isAssetSHA(hash) else { return false }
        if database.readBlobFile(hash: hash) != nil { return true }
        for root in blobSearchRoots() {
            let remote = root.appendingPathComponent(hash + ".bin")
            startDownloadIfNeeded(remote)
            if readCloudData(remote, attempts: 4, delayMs: 80) != nil || fm.fileExists(atPath: remote.path) {
                database.importBlobIfNeeded(hash: hash, from: remote)
                if database.readBlobFile(hash: hash) != nil { return true }
            }
        }
        return false
    }

    private func enqueueArchive(itemId: UUID, htmlSHA: String, metaJSON: String, blobKeys: [String]?) {
        let keys: [String]
        if let blobKeys, !blobKeys.isEmpty {
            keys = uniqueKeys(blobKeys)
        } else if let data = database.readBlobFile(hash: htmlSHA),
                  let html = String(data: data, encoding: .utf8) {
            keys = ArchiveBlobClosure.keys(root: htmlSHA, html: html)
        } else {
            keys = [htmlSHA.lowercased()]
        }
        var meta = ArchiveBlobClosure.parseMeta(metaJSON)
        if let data = database.readBlobFile(hash: htmlSHA),
           let html = String(data: data, encoding: .utf8) {
            ArchiveBlobClosure.stamp(&meta, root: htmlSHA, html: html)
        } else {
            meta["closure"] = ["v": 1, "root": htmlSHA.lowercased(), "blobs": keys] as [String: Any]
        }
        var op = makeOp(
            kind: "web_archive",
            itemId: itemId.uuidString,
            item: nil,
            blobKeys: keys
        )
        op.contentHash = htmlSHA.lowercased()
        op.note = ArchiveBlobClosure.encodeMeta(meta)
        enqueue(op)
        scheduleDrain(reason: "web_archive")
    }

    private func uniqueKeys(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in keys {
            let k = raw.lowercased()
            guard ArchiveImageInliner.isAssetSHA(k), !seen.contains(k) else { continue }
            seen.insert(k)
            out.append(k)
        }
        return out
    }

    func recordLocalCompose(item: ClipboardItem) {
        guard config.enabled else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let keys = ComposeNotes.blobKeys(in: item.textContent ?? "")
            var op = self.makeOp(
                kind: "compose",
                itemId: item.id.uuidString,
                item: item,
                blobKeys: keys.isEmpty ? nil : keys
            )
            op.type = ClipboardType.note.rawValue
            op.sourceApp = ComposeNotes.sourceApp
            op.note = "compose"
            self.enqueue(op)
            self.scheduleDrain(reason: "compose")
        }
    }

    func recordLocalReaderOp(itemId: UUID, opId: String, kind: String, payload: [String: Any], ts: Double, source: String) {
        guard config.enabled else { return }
        queue.async { [weak self] in
            guard let self else { return }
            var op = self.makeOp(
                kind: "reader_op",
                itemId: itemId.uuidString,
                item: nil,
                blobKeys: nil
            )
            if let eid = UUID(uuidString: opId) {
                op.opId = eid.uuidString
            }
            op.wallTs = ts
            let body: [String: Any] = [
                "kind": kind,
                "payload": payload,
                "ts": ts,
                "source": source,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: body),
               let raw = String(data: data, encoding: .utf8) {
                op.note = raw
            }
            self.enqueue(op)
            self.scheduleDrain(reason: "reader_op")
        }
    }

    @available(*, deprecated, message: "Use recordLocalUserEvaluation")
    func recordLocalUserContext(item: ClipboardItem) {
        recordLocalUserEvaluation(
            item: item,
            evaluationId: UUID().uuidString,
            rating: item.userRating,
            note: item.userNote
        )
    }

    func runNow(completion: ((Bool, String) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.cycle(reason: "manual") { ok, msg in
                DispatchQueue.main.async { completion?(ok, msg) }
            }
        }
    }

    func setEnabled(_ on: Bool, completion: ((Config) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.config.enabled = on
            Self.saveConfig(self.config)
            if on {
                self.cycle(reason: "enable")
            }
            self.publishStatus()
            let c = self.config
            DispatchQueue.main.async { completion?(c) }
        }
    }

    func statusSnapshot(completion: @escaping (Status) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let st = self.buildStatus()
            DispatchQueue.main.async { completion(st) }
        }
    }

    // MARK: Cycle

    private var drainWorkItem: DispatchWorkItem?

    private func scheduleDrain(reason: String) {
        drainWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.cycle(reason: reason)
        }
        drainWorkItem = work
        // Short coalesce so bursty copies don't thrash File Provider.
        queue.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func cycle(reason: String, completion: ((Bool, String) -> Void)? = nil) {
        guard config.enabled else {
            completion?(false, "sync disabled")
            return
        }
        guard !inProgress else {
            completion?(false, "sync in progress")
            return
        }
        inProgress = true
        lastPhase = "cycle:\(reason)"
        lastError = nil
        publishStatus()

        var messages: [String] = []
        var okAll = true

        // 1) Push local outbox (+ CAS)
        lastPhase = "push"
        let pushed = pushOutbox()
        messages.append(pushed.message)
        okAll = okAll && pushed.ok
        if pushed.ok { lastPushUnix = Date().timeIntervalSince1970 }

        // 2) Pull remote ops
        lastPhase = "pull"
        let pulled = pullRemote()
        messages.append(pulled.message)
        okAll = okAll && pulled.ok
        if pulled.ok { lastPullUnix = Date().timeIntervalSince1970 }

        lastPhase = okAll ? "ok" : "partial"
        if !okAll, lastError == nil {
            lastError = messages.joined(separator: " · ")
        }
        inProgress = false
        publishStatus()
        completion?(okAll, messages.joined(separator: " · "))
    }

    // MARK: Outbox / push

    private func localSyncDir() -> URL {
        let root = DatabaseManager.resolveDataRoot().appendingPathComponent("sync", isDirectory: true)
        try? fm.createDirectory(at: root.appendingPathComponent("outbox", isDirectory: true), withIntermediateDirectories: true)
        return root
    }

    private func outboxDir() -> URL {
        localSyncDir().appendingPathComponent("outbox", isDirectory: true)
    }

    private func highestLocalOutboxSeq() -> Int {
        let dir = outboxDir()
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var best = 0
        for f in files where f.pathExtension == "json" {
            if let n = Int(f.deletingPathExtension().lastPathComponent) {
                best = max(best, n)
            }
        }
        return best
    }

    private func makeOp(kind: String, itemId: String, item: ClipboardItem?, blobKeys: [String]?) -> SyncOp {
        let seq = nextSeq
        nextSeq += 1
        persistNextSeq()
        let wall = item?.timestamp.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        let hlc = String(format: "%.0f-%@-%d", wall * 1000, hostId, seq)
        return SyncOp(
            opId: UUID().uuidString,
            host: hostId,
            seq: seq,
            kind: kind,
            itemId: itemId,
            contentHash: item?.contentHash,
            type: item?.type.rawValue,
            wallTs: wall,
            hlc: hlc,
            textContent: item?.textContent,
            htmlContent: item?.htmlContent,
            ocrText: item?.ocrText,
            sourceApp: item?.sourceApp,
            url: item?.url?.absoluteString,
            fileUrls: item?.fileURLs?.map(\.path),
            copyCount: 1,
            blobKeys: blobKeys,
            note: nil
        )
    }

    private func persistNextSeq() {
        let sem = DispatchSemaphore(value: 0)
        database.performSyncWork {
            self.database.metaSetSync("sync.next_seq", String(self.nextSeq))
            sem.signal()
        }
        sem.wait()
    }

    private func enqueue(_ op: SyncOp) {
        let url = outboxDir().appendingPathComponent(String(format: "%016d.json", op.seq))
        do {
            let data = try encoder.encode(op)
            try data.write(to: url, options: .atomic)
            lastPhase = "outbox:\(op.seq)"
        } catch {
            lastError = "outbox write: \(error.localizedDescription)"
            print("[Sync] outbox write failed: \(error)")
        }
        publishStatus()
    }

    private struct StepResult {
        var ok: Bool
        var message: String
    }


    // MARK: CloudDocs materialization (File Provider dataless)

    /// Trigger download + read bytes for a CloudDocs path. Without this, `Data(contentsOf:)`
    /// often fails with "Resource deadlock avoided" on dataless placeholders and peers stay empty.
    @discardableResult
    private func startDownloadIfNeeded(_ url: URL) -> Bool {
        var isUbiq: Any? = nil
        do {
            let vals = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            if vals.isUbiquitousItem == true {
                let status = vals.ubiquitousItemDownloadingStatus
                if status != URLUbiquitousItemDownloadingStatus.current {
                    try? fm.startDownloadingUbiquitousItem(at: url)
                    return true
                }
            }
            _ = isUbiq
        } catch {
            // Not ubiquitous / key unsupported — still try read.
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
        return false
    }

    private func readCloudData(_ url: URL, attempts: Int = 8, delayMs: UInt32 = 120) -> Data? {
        guard fm.fileExists(atPath: url.path) else {
            // Parent may be dataless directory placeholder — request download of parent if any.
            startDownloadIfNeeded(url)
            return nil
        }
        startDownloadIfNeeded(url)
        for i in 0..<attempts {
            if let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty {
                return data
            }
            // Evict "Resource deadlock avoided" / partial by re-requesting download.
            startDownloadIfNeeded(url)
            if i + 1 < attempts {
                usleep(delayMs * 1000 * UInt32(i + 1))
            }
        }
        return nil
    }

    private func kickPeerOpsDownload(host: String, fromSeq: Int, toSeq: Int, root: URL) {
        for dir in [trxDir(in: root, host: host), legacyOpsDir(in: root, host: host)] {
            startDownloadIfNeeded(dir)
            let end = min(toSeq, fromSeq + 120)
            var s = max(1, fromSeq + 1)
            while s <= end {
                startDownloadIfNeeded(dir.appendingPathComponent(String(format: "%016d.json", s)))
                s += 1
            }
        }
    }

    /// Highest seq on disk. `trx/` is canonical; leftover `ops/` still counts.
    private func discoverMaxOpSeq(host: String, root: URL) -> Int {
        max(maxSeqInDir(trxDir(in: root, host: host)), maxSeqInDir(legacyOpsDir(in: root, host: host)))
    }

    private func maxSeqInDir(_ dir: URL) -> Int {
        startDownloadIfNeeded(dir)
        let files = ((try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension == "json" }
        var maxSeq = 0
        for f in files {
            let name = f.deletingPathExtension().lastPathComponent
            if let n = Int(name), n > maxSeq { maxSeq = n }
        }
        return maxSeq
    }

    /// Prefer `trx/{host}/{seq}.json`; fall back to leftover `ops/`.
    private func readTxData(host: String, seq: Int, root: URL) -> Data? {
        let name = String(format: "%016d.json", seq)
        let trx = trxDir(in: root, host: host).appendingPathComponent(name)
        let legacy = legacyOpsDir(in: root, host: host).appendingPathComponent(name)
        startDownloadIfNeeded(trx)
        startDownloadIfNeeded(legacy)
        if let data = readCloudData(trx) { return data }
        return readCloudData(legacy)
    }

    private func pushOutbox() -> StepResult {
        guard let syncRoot = syncRootURL(), let casRoot = casBlobsURL() else {
            lastError = "CloudDocs unavailable"
            return StepResult(ok: false, message: "no CloudDocs")
        }
        ensureDir(syncRoot)
        ensureDir(trxDir(in: syncRoot, host: hostId))
        ensureDir(headsDir(in: syncRoot))
        ensureDir(casRoot)

        let files = ((try? fm.contentsOfDirectory(
            at: outboxDir(),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        if files.isEmpty {
            // Still refresh head so peers see liveness.
            writeHead(seq: max(0, nextSeq - 1), lastOpId: nil, root: syncRoot)
            return StepResult(ok: true, message: "push:idle")
        }

        var published = 0
        var lastOp: SyncOp?
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let op = try? decoder.decode(SyncOp.self, from: data) else {
                continue
            }
            // CAS first
            if let keys = op.blobKeys {
                for key in keys {
                    if !publishBlob(key: key, to: casRoot) {
                        lastError = "blob missing local \(key)"
                        return StepResult(ok: false, message: "push:blob_missing \(key)")
                    }
                }
            }
            let dest = trxDir(in: syncRoot, host: hostId)
                .appendingPathComponent(String(format: "%016d.json", op.seq))
            do {
                try publishJSONAtomic(data, to: dest)
                try? fm.removeItem(at: file)
                published += 1
                lastOp = op
            } catch {
                lastError = "push op \(op.seq): \(error.localizedDescription)"
                return StepResult(ok: false, message: "push:fail \(op.seq)")
            }
        }
        if let lastOp {
            writeHead(seq: lastOp.seq, lastOpId: lastOp.opId, root: syncRoot)
        } else {
            writeHead(seq: max(0, nextSeq - 1), lastOpId: nil, root: syncRoot)
        }
        return StepResult(ok: true, message: "push:\(published)")
    }

    private func publishBlob(key: String, to casRoot: URL) -> Bool {
        let local = database.blobFileURL(hash: key)
        guard fm.fileExists(atPath: local.path) else { return false }
        let dest = casRoot.appendingPathComponent(key + ".bin")
        if fm.fileExists(atPath: dest.path) {
            let ls = (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            let ds = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
            if ls == ds, ls > 0 { return true }
            try? fm.removeItem(at: dest)
        }
        do {
            try fullCopy(from: local, to: dest)
            return true
        } catch {
            print("[Sync] blob publish failed \(key): \(error)")
            return false
        }
    }

    // MARK: Pull / merge

    private func pullRemote() -> StepResult {
        guard let syncRoot = syncRootURL() else {
            return StepResult(ok: false, message: "pull:no CloudDocs")
        }
        if let attach = casBlobsURL() { ensureDir(attach) }
        let heads = headsDir(in: syncRoot)
        ensureDir(heads)
        let headFiles = ((try? fm.contentsOfDirectory(
            at: heads,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension == "json" }

        var appliedTotal = 0
        var peerNotes: [String] = []

        for headFile in headFiles {
            startDownloadIfNeeded(headFile)
            guard let data = readCloudData(headFile),
                  let head = try? decoder.decode(HostHead.self, from: data) else { continue }
            if head.host == hostId { continue }
            // head.seq can lag behind real op files (producer push wrote ops but head rewrite failed / iCloud stale).
            let diskMax = discoverMaxOpSeq(host: head.host, root: syncRoot)
            let targetSeq = max(head.seq, diskMax)
            peerRemoteSeq[head.host] = targetSeq
            if diskMax > head.seq {
                print("[Sync] peer \(head.host) head.seq=\(head.seq) but trx disk max=\(diskMax) — using disk max")
            }

            var applied = 0
            database.performSyncWork {
                // run applied cursor read/write + DB apply on db queue via nested sync — we use a lock pattern:
            }
            // Use a serial handshake: pull ops on sync queue, apply via performSyncWork with semaphore.
            let appliedBefore = appliedSeq(for: head.host)
            var cursor = appliedBefore
            let limit = config.pullBatchLimit
            var batch = 0
            kickPeerOpsDownload(host: head.host, fromSeq: cursor, toSeq: targetSeq, root: syncRoot)
            while cursor < targetSeq, batch < limit {
                let next = cursor + 1
                guard let opData = readTxData(host: head.host, seq: next, root: syncRoot),
                      let op = try? decoder.decode(SyncOp.self, from: opData) else {
                    lastPhase = "pull:wait \(head.host)#\(next)"
                    break
                }
                // Import blobs
                if let keys = op.blobKeys {
                    for key in keys {
                        var imported = false
                        for root in blobSearchRoots() {
                            let remote = root.appendingPathComponent(key + ".bin")
                            startDownloadIfNeeded(remote)
                            if readCloudData(remote, attempts: 4, delayMs: 80) != nil || fm.fileExists(atPath: remote.path) {
                                database.importBlobIfNeeded(hash: key, from: remote)
                                imported = database.readBlobFile(hash: key) != nil
                                if imported { break }
                            }
                        }
                        if !imported && needsBlob(op: op, key: key) {
                            lastPhase = "pull:blob_wait \(key)"
                            break
                        }
                    }
                    if keys.contains(where: { database.readBlobFile(hash: $0) == nil && needsBlob(op: op, key: $0) }) {
                        break
                    }
                }

                let sem = DispatchSemaphore(value: 0)
                var changed = false
                var appliedOk = false
                database.performSyncWork {
                    changed = self.applyOpLocked(op)
                    appliedOk = changed || self.applyIsIdempotentSuccess(op)
                    if appliedOk {
                        self.database.metaSetSync(self.appliedKey(host: head.host), String(next))
                    }
                    sem.signal()
                }
                sem.wait()
                if !appliedOk {
                    lastPhase = "pull:retry \(op.kind) \(op.itemId.prefix(8))"
                    break
                }
                if op.kind == "web_archive" {
                    hydrateArchiveDependents(
                        htmlSHA: op.contentHash ?? op.blobKeys?.first,
                        listed: op.blobKeys
                    )
                }
                cursor = next
                applied += 1
                batch += 1
                if changed {
                    NotificationCenter.default.post(name: Notification.Name("ClipFlowItemAdded"), object: nil)
                }
            }
            appliedTotal += applied
            peerNotes.append("\(head.host)+\(applied)/@\(cursor)")
        }

        return StepResult(ok: true, message: "pull:\(appliedTotal) [\(peerNotes.joined(separator: ","))]")
    }

    private func needsBlob(op: SyncOp, key: String) -> Bool {
        if op.kind == "web_archive" || op.kind == "compose" { return true }
        // Text-only upserts may list empty blobKeys; if key listed, require it for image/rtf/pdf types.
        guard let t = op.type else { return true }
        switch t {
        case "image", "rtf", "pdf": return true
        default: return key.hasSuffix(".rtf") || key.hasSuffix(".pdf")
        }
    }

    private func applyOpLocked(_ op: SyncOp) -> Bool {
        guard let uuid = UUID(uuidString: op.itemId) else { return false }
        switch op.kind {
        case "tombstone":
            return database.applySyncTombstoneLocked(id: uuid)
        case "user_context", "user_evaluation":
            // Each peer evaluation is one history row (idempotent by op_id / evaluation id).
            let evalId = UUID(uuidString: op.opId)
            do {
                _ = try database.applyUserContextLocked(
                    id: uuid,
                    note: op.userNote,
                    rating: op.userRating,
                    evaluationId: evalId,
                    source: "sync:\(op.host)"
                )
                return true
            } catch DatabaseManager.UserContextError.emptyUpdate {
                return false
            } catch {
                print("[Sync] user_evaluation apply failed \(op.itemId): \(error)")
                return false
            }
        case "pin", "unpin":
            return database.applySyncPinLocked(
                id: uuid,
                pinned: op.kind == "pin",
                pinnedAt: Date(timeIntervalSince1970: op.wallTs)
            )
        case "web_archive":
            return database.applySyncArchiveLocked(
                id: uuid,
                htmlSHA: op.contentHash ?? op.blobKeys?.first,
                metaJSON: op.note,
                htmlFallback: op.htmlContent
            )
        case "compose":
            return database.applySyncComposeLocked(
                id: uuid,
                opId: op.opId,
                timestamp: Date(timeIntervalSince1970: op.wallTs),
                contentHash: op.contentHash ?? ComposeNotes.contentHash(id: uuid, body: op.textContent ?? ""),
                body: op.textContent ?? "",
                refURLString: op.url,
                blobKeysJSON: {
                    guard let keys = op.blobKeys, let data = try? JSONSerialization.data(withJSONObject: keys) else { return nil }
                    return String(data: data, encoding: .utf8)
                }(),
                source: "sync:\(op.host)"
            )
        case "reader_op":
            return database.applySyncReaderOpLocked(
                itemId: uuid,
                opId: op.opId,
                noteJSON: op.note,
                wallTs: op.wallTs,
                source: "sync:\(op.host)"
            )
        case "clip_link":
            return database.applySyncClipLinkLocked(
                opId: op.opId,
                itemId: uuid,
                noteJSON: op.note,
                contentHash: op.contentHash,
                wallTs: op.wallTs,
                source: "sync:\(op.host)"
            )
        case "upsert", "touch":
            guard let hash = op.contentHash, let type = op.type else { return false }
            return database.applySyncUpsertLocked(
                id: uuid,
                timestamp: Date(timeIntervalSince1970: op.wallTs),
                typeRaw: type,
                contentHash: hash,
                textContent: op.textContent,
                htmlContent: op.htmlContent,
                ocrText: op.ocrText,
                sourceApp: op.sourceApp,
                urlString: op.url,
                fileURLPaths: op.fileUrls,
                copyCount: op.copyCount ?? 1
            )
        default:
            return false
        }
    }

    /// `applyOpLocked` returns false for no-op upserts; those must not stall the cursor.
    /// Failed pin/archive/reader while the clip is missing must retry.
    private func applyIsIdempotentSuccess(_ op: SyncOp) -> Bool {
        switch op.kind {
        case "reader_op", "pin", "unpin", "web_archive", "compose", "clip_link":
            return false
        default:
            return true
        }
    }

    /// Re-apply every on-disk `reader_op` (trx/ + leftover ops/). INSERT OR IGNORE.
    func replayDiskReaderOps() {
        queue.async { [weak self] in
            guard let self, let root = self.syncRootURL() else { return }
            var files: [URL] = []
            for hostDir in (try? self.fm.contentsOfDirectory(
                at: root.appendingPathComponent("trx", isDirectory: true),
                includingPropertiesForKeys: nil
            )) ?? [] {
                files.append(contentsOf: self.listJson(in: hostDir))
            }
            for hostDir in (try? self.fm.contentsOfDirectory(
                at: root.appendingPathComponent("ops", isDirectory: true),
                includingPropertiesForKeys: nil
            )) ?? [] {
                files.append(contentsOf: self.listJson(in: hostDir))
            }
            let decoder = JSONDecoder()
            var n = 0
            self.database.performSyncWork {
                for url in files {
                    guard let data = try? Data(contentsOf: url),
                          let op = try? decoder.decode(SyncOp.self, from: data),
                          op.kind == "reader_op" else { continue }
                    if self.applyOpLocked(op) { n += 1 }
                }
            }
            if n > 0 {
                print("[Sync] replayDiskReaderOps applied \(n)")
            }
        }
    }

    /// Re-apply every on-disk `clip_link` (trx/ + leftover ops/). INSERT OR IGNORE all, then fold by pair_key.
    func replayDiskClipLinks() {
        queue.async { [weak self] in
            guard let self, let root = self.syncRootURL() else { return }
            var files: [URL] = []
            for hostDir in (try? self.fm.contentsOfDirectory(
                at: root.appendingPathComponent("trx", isDirectory: true),
                includingPropertiesForKeys: nil
            )) ?? [] {
                files.append(contentsOf: self.listJson(in: hostDir))
            }
            for hostDir in (try? self.fm.contentsOfDirectory(
                at: root.appendingPathComponent("ops", isDirectory: true),
                includingPropertiesForKeys: nil
            )) ?? [] {
                files.append(contentsOf: self.listJson(in: hostDir))
            }
            let decoder = JSONDecoder()
            var n = 0
            self.database.performSyncWork {
                var pairKeys = Set<String>()
                var itemIds = Set<String>()
                var hashes = Set<String>()
                for url in files {
                    guard let data = try? Data(contentsOf: url),
                          let op = try? decoder.decode(SyncOp.self, from: data),
                          op.kind == "clip_link" else { continue }
                    guard let raw = op.note, let noteData = raw.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: noteData) as? [String: Any] else {
                        continue
                    }
                    let pairKey = (obj["pair_key"] as? String) ?? ""
                    let action = (obj["action"] as? String) ?? ""
                    let fromId = (obj["from_item_id"] as? String) ?? op.itemId
                    let toItemId = obj["to_item_id"] as? String
                    let toHash = (obj["to_content_hash"] as? String) ?? op.contentHash
                    let toIsNote = DatabaseManager.jsonFlag(obj["to_is_note"])
                    let kind = (obj["kind"] as? String) ?? "related"
                    if let key = self.database.ingestClipLinkReplayLocked(
                        opId: op.opId,
                        ts: op.wallTs,
                        action: action,
                        fromItemId: fromId,
                        toContentHash: toHash,
                        toItemId: toItemId,
                        toIsNote: toIsNote,
                        kind: kind,
                        pairKey: pairKey,
                        source: "replay:\(op.host)"
                    ) {
                        n += 1
                        pairKeys.insert(key)
                        itemIds.insert(UUID(uuidString: fromId)?.uuidString ?? fromId)
                        if let toItemId { itemIds.insert(UUID(uuidString: toItemId)?.uuidString ?? toItemId) }
                        if let toHash { hashes.insert(toHash.lowercased()) }
                    }
                }
                self.database.finishClipLinkReplayLocked(pairKeys: pairKeys, itemIds: itemIds, hashes: hashes)
            }
            if n > 0 {
                print("[Sync] replayDiskClipLinks applied \(n)")
            }
        }
    }

    /// Old `web_archive` rows listed only the HTML sha. Rebuild the document closure,
    /// hydrate missing CAS from live/attach or host backup replicas, and emit one
    /// complete trx so later peers do not depend on backup.
    private func repairArchiveClosures() {
        let pointers = database.archivedPointers()
        guard !pointers.isEmpty else { return }
        var republished = 0
        var hydrated = 0
        for (id, sha) in pointers {
            guard let html = database.fetchArchiveHTML(id: id) else { continue }
            let oldMeta = database.webArchiveMetaJSON(id: id)
            let oldKeys = Set(ArchiveBlobClosure.blobs(fromMeta: oldMeta) ?? [])
            var meta = ArchiveBlobClosure.parseMeta(oldMeta)
            let keys = ArchiveBlobClosure.stamp(&meta, root: sha, html: html)
            for key in keys where database.readBlobFile(hash: key) == nil {
                if hydrateBlob(key) { hydrated += 1 }
            }
            let stamped = ArchiveBlobClosure.encodeMeta(meta)
            let sem = DispatchSemaphore(value: 0)
            database.performSyncWork {
                self.database.metaSetSync("archive.\(id.uuidString)", stamped)
                sem.signal()
            }
            sem.wait()
            let missing = keys.contains { database.readBlobFile(hash: $0) == nil }
            let alreadyListed = !keys.isEmpty && Set(keys).isSubset(of: oldKeys)
            if !missing, !alreadyListed, config.enabled {
                enqueueArchive(itemId: id, htmlSHA: sha, metaJSON: ArchiveBlobClosure.encodeMeta(meta), blobKeys: keys)
                republished += 1
            }
        }
        if hydrated > 0 || republished > 0 {
            print("[Sync] archive closure repair hydrated=\(hydrated) republished=\(republished)")
        }
    }

    /// After applying a possibly incomplete trx, pull dependents named by the HTML.
    private func hydrateArchiveDependents(htmlSHA: String?, listed: [String]?) {
        let listed = Set((listed ?? []).map { $0.lowercased() })
        var extra: [String] = []
        if let htmlSHA, let data = database.readBlobFile(hash: htmlSHA),
           let html = String(data: data, encoding: .utf8) {
            extra = ArchiveBlobClosure.refs(inHTML: html)
        }
        for key in extra where !listed.contains(key) {
            _ = hydrateBlob(key)
        }
    }

    private func listJson(in dir: URL) -> [URL] {
        ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    private func appliedKey(host: String) -> String { "sync.applied.\(host)" }

    private func appliedSeq(for host: String) -> Int {
        var value = 0
        let sem = DispatchSemaphore(value: 0)
        database.performSyncWork {
            if let s = self.database.metaGetSync(self.appliedKey(host: host)), let n = Int(s) {
                value = n
            }
            sem.signal()
        }
        sem.wait()
        return value
    }

    // MARK: Bootstrap local history → outbox (once)

    private func bootstrapLocalHistoryIfNeeded() {
        let sem = DispatchSemaphore(value: 0)
        var done = false
        database.performSyncWork {
            done = self.database.metaGetSync("sync.bootstrapped") == "1"
            sem.signal()
        }
        sem.wait()
        guard !done else { return }
        lastPhase = "bootstrap"
        // Export pages and enqueue upserts without spamming CloudDocs mid-loop;
        // drain happens in cycle.
        var cursor: ClipCursor? = nil
        var total = 0
        let pageLimit = 50
        let group = DispatchGroup()
        var keepGoing = true
        while keepGoing {
            group.enter()
            var pageItems: [ClipboardItem] = []
            var next: ClipCursor?
            database.exportItemsForSync(limit: pageLimit, cursor: cursor) { items, n in
                pageItems = items
                next = n
                group.leave()
            }
            group.wait()
            if pageItems.isEmpty {
                keepGoing = false
                break
            }
            for item in pageItems {
                let keys = database.existingBlobKeys(for: item.contentHash)
                let op = makeOp(kind: "upsert", itemId: item.id.uuidString, item: item, blobKeys: keys)
                enqueue(op)
                total += 1
            }
            cursor = next
            if next == nil { keepGoing = false }
            // Safety cap for huge histories: remaining items still sync on future captures;
            // full history can re-run after meta clear. 5k is plenty for personal clipboard.
            if total >= 5000 { keepGoing = false }
        }
        database.performSyncWork {
            self.database.metaSetSync("sync.bootstrapped", "1")
        }
        print("[Sync] bootstrapped \(total) local items into outbox")
        lastPhase = "bootstrap:\(total)"
    }

    // MARK: Paths

    private func syncRootURL() -> URL? {
        BackupDestinationResolver.cloudDocsURL()?
            .appendingPathComponent("ClipFlow/sync/v1", isDirectory: true)
    }

    /// Live attachments. Not the backup CAS tree.
    private func casBlobsURL() -> URL? {
        BackupDestinationResolver.cloudDocsURL()?
            .appendingPathComponent("ClipFlow/live/attach", isDirectory: true)
    }

    /// Pull may still find bytes published under the old shared backup CAS.
    private func blobSearchRoots() -> [URL] {
        var roots: [URL] = []
        if let live = casBlobsURL() { roots.append(live) }
        guard let cloud = BackupDestinationResolver.cloudDocsURL() else { return roots }
        roots.append(cloud.appendingPathComponent("ClipFlow/backup/blobs", isDirectory: true))
        let hosts = cloud.appendingPathComponent("ClipFlow/backup/hosts", isDirectory: true)
        let hostDirs = (try? fm.contentsOfDirectory(
            at: hosts,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for dir in hostDirs {
            roots.append(dir.appendingPathComponent("blobs", isDirectory: true))
        }
        return roots
    }

    private func trxDir(in root: URL, host: String) -> URL {
        root.appendingPathComponent("trx/\(host)", isDirectory: true)
    }

    private func legacyOpsDir(in root: URL, host: String) -> URL {
        root.appendingPathComponent("ops/\(host)", isDirectory: true)
    }

    private func headsDir(in root: URL) -> URL {
        root.appendingPathComponent("heads", isDirectory: true)
    }

    private func ensureDir(_ url: URL) {
        // Stepwise for File Provider friendliness
        var partial = URL(fileURLWithPath: "/")
        let parts = url.path.split(separator: "/").map(String.init)
        for p in parts {
            partial = partial.appendingPathComponent(p, isDirectory: true)
            if !fm.fileExists(atPath: partial.path) {
                try? fm.createDirectory(at: partial, withIntermediateDirectories: false)
            }
        }
    }

    private func writeHead(seq: Int, lastOpId: String?, root: URL) {
        let head = HostHead(
            host: hostId,
            seq: seq,
            lastOpId: lastOpId,
            wallTs: Date().timeIntervalSince1970,
            itemHint: nil,
            updatedAt: ClipTimeFormat.isoLocal()
        )
        let url = headsDir(in: root).appendingPathComponent("\(hostId).json")
        guard let data = try? encoder.encode(head) else { return }
        try? publishJSONAtomic(data, to: url)
    }

    private func publishJSONAtomic(_ data: Data, to dest: URL) throws {
        ensureDir(dest.deletingLastPathComponent())
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".tmp_\(UUID().uuidString).json")
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: tmp, to: dest)
    }

    private func fullCopy(from src: URL, to dst: URL) throws {
        ensureDir(dst.deletingLastPathComponent())
        let tmp = dst.deletingLastPathComponent()
            .appendingPathComponent(".tmp_\(UUID().uuidString)_\(dst.lastPathComponent)")
        if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
        try fm.copyItem(at: src, to: tmp)
        if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
        try fm.moveItem(at: tmp, to: dst)
    }

    // MARK: Host / config

    private static var configURL: URL {
        DatabaseManager.resolveDataRoot().appendingPathComponent("config/sync.json")
    }

    private static func loadConfig() -> Config {
        if let data = try? Data(contentsOf: configURL),
           let c = try? JSONDecoder().decode(Config.self, from: data) {
            return c
        }
        let c = Config.default
        saveConfig(c)
        return c
    }

    private static func saveConfig(_ c: Config) {
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(c) {
            try? data.write(to: configURL, options: .atomic)
        }
    }

    private func startPollTimer() {
        pollTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(15, config.pollIntervalSeconds)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            self?.cycle(reason: "poll")
        }
        t.resume()
        pollTimer = t
    }

    private func outboxPendingCount() -> Int {
        let files = (try? fm.contentsOfDirectory(at: outboxDir(), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension == "json" }.count
    }

    private func buildStatus() -> Status {
        let root = syncRootURL()
        var peers: [PeerStatus] = []
        if let root {
            let heads = headsDir(in: root)
            let files = ((try? fm.contentsOfDirectory(at: heads, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension == "json" }
            for f in files {
                startDownloadIfNeeded(f)
                guard let data = readCloudData(f, attempts: 4, delayMs: 50),
                      let head = try? decoder.decode(HostHead.self, from: data),
                      head.host != hostId else { continue }
                let applied = appliedSeq(for: head.host)
                let diskMax = discoverMaxOpSeq(host: head.host, root: root)
                peers.append(PeerStatus(
                    host: head.host,
                    remoteSeq: max(head.seq, diskMax),
                    appliedSeq: applied,
                    lag: max(0, head.seq - applied)
                ))
            }
        }
        return Status(
            enabled: config.enabled,
            hostId: hostId,
            localSeq: max(0, nextSeq - 1),
            outboxPending: outboxPendingCount(),
            cloudDocsAvailable: root != nil,
            syncRootPath: root?.path,
            trxPath: root.map { trxDir(in: $0, host: hostId).path },
            lastPushAt: lastPushUnix.map { ClipTimeFormat.isoLocal(unix: $0) },
            lastPullAt: lastPullUnix.map { ClipTimeFormat.isoLocal(unix: $0) },
            lastPushUnix: lastPushUnix,
            lastPullUnix: lastPullUnix,
            lastPhase: lastPhase,
            lastError: lastError,
            inProgress: inProgress,
            peers: peers.sorted { $0.host < $1.host },
            pollIntervalSeconds: config.pollIntervalSeconds,
            policy: "per-host trx/ · cloud transport · eventual consistency · poll \(Int(config.pollIntervalSeconds))s · never whole-db replace"
        )
    }

    private func publishStatus() {
        NotificationCenter.default.post(name: Self.statusChangedNotification, object: nil)
    }
}
