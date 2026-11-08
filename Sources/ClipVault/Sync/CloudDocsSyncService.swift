import Foundation
import CryptoKit

/// Multi-device **eventual consistency** for the per-host transaction log.
///
/// ## Two planes (do not conflate)
/// - **Backup** (`CloudDocsBackupService` + `OstoreBackup`): per-host disaster snapshot. Never a sync bus.
/// - **Live** (this type): append-only transactions per host; attachments next to the log.
///
/// ## One protocol, three wires (`Config.transport`)
/// ```text
///   clouddocs   iCloud Drive File Provider        poll, 45 s, dataless downloads
///   ostore      HTTP object store + SSE           event-driven, < 3 s
///   both        publish to both, pull from either (cursors are per host, not per wire)
/// ```
/// The trx JSON, seq numbering, cursors and apply rules are identical on every wire,
/// so a fleet may mix them: an op pulled from either wire advances the same
/// `sync.applied.{host}` cursor and is applied at most once.
///
/// ```
/// …/CloudDocs/ClipFlow/sync/v1/                     (clouddocs)
///   trx/{host_id}/{seq:016d}.json     # transactions (write here)
///   ops/{host_id}/{seq:016d}.json     # legacy, read-only fallback
///   heads/{host_id}.json
/// …/CloudDocs/ClipFlow/live/attach/{key}.bin
///
/// {ostorePrefix}/trx/{host_id}/{seq:016d}.json      (ostore)
/// {ostorePrefix}/attach/{key}.bin
/// {ostorePrefix}/heads/{host_id}.json
/// ```
///
/// Local: outbox under `KEEPSAKE_HOME/sync/outbox/`, cursors in `keepsake_meta`.
/// Wire details: `OstoreSyncWire`. Design: `docs/ostore-sync.md`.
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
        /// `clouddocs` | `ostore` | `both` — see the type doc. Default keeps iCloud.
        var transport: String = "clouddocs"
        /// Object prefix inside the ostore root. One store can host several fleets.
        var ostorePrefix: String = "clipvault/sync/v1"
        /// Safety-net cadence while the ostore event stream is up (events do the work).
        var ostoreOnlinePollSeconds: Double = 30
        /// Safety-net cadence while the event stream is down. 1.5 s keeps a poll-driven
        /// cycle inside the 3 s budget too (a cycle costs ~0.5–1.2 s on its own).
        var ostoreOfflinePollSeconds: Double = 1.5
        static let `default` = Config()

        /// Synthesized `Decodable` ignores property defaults, so an existing
        /// `sync.json` (written before ostore existed) must not fail to decode.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
            pollIntervalSeconds = (try? c.decodeIfPresent(Double.self, forKey: .pollIntervalSeconds)) ?? 45
            pullBatchLimit = (try? c.decodeIfPresent(Int.self, forKey: .pullBatchLimit)) ?? 200
            transport = (try? c.decodeIfPresent(String.self, forKey: .transport)) ?? "clouddocs"
            ostorePrefix = (try? c.decodeIfPresent(String.self, forKey: .ostorePrefix)) ?? "clipvault/sync/v1"
            ostoreOnlinePollSeconds = (try? c.decodeIfPresent(Double.self, forKey: .ostoreOnlinePollSeconds)) ?? 30
            ostoreOfflinePollSeconds = (try? c.decodeIfPresent(Double.self, forKey: .ostoreOfflinePollSeconds)) ?? 1.5
        }
        init() {}

        /// Does this fleet publish/pull over ostore at all?
        var usesOstore: Bool { transport == "ostore" || transport == "both" }
        /// Does it still use iCloud Drive?
        var usesCloudDocs: Bool { transport != "ostore" }
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
        var parentHash: String?
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
            case blobKeys = "blob_keys", parentHash = "parent_hash", note
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
        /// `clouddocs` | `ostore` | `both` — the wire(s) this install uses.
        var transport: String = "clouddocs"
        var ostorePrefix: String? = nil
        /// Host only: the ostore base URL never carries a token, but keep the panel short.
        var ostoreBaseHost: String? = nil
        /// Live event stream state. `false` means the 3 s poll fallback is carrying sync.
        var ostoreConnected: Bool = false
        var ostoreLastEventUnix: Double? = nil
    }

    // MARK: State

    private let database: DatabaseManager
    private let queue = DispatchQueue(label: "com.clipvault.sync.clouddocs", qos: .utility)
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

    // ostore wire (optional). One instance per process; credentials from
    // `config/ostore-backup.json`. nil when the file is missing / not https.
    private var ostoreWire: OstoreSyncWire?
    private var ostoreConnected = false
    private var ostoreLastEventUnix: Double?
    /// Attachments this process already published (content-addressed: key == digest).
    private var publishedAttachments: Set<String> = []
    /// Attachment downloads in flight (touched on `queue` only).
    private var prefetching: Set<String> = []
    private let prefetchQueue = DispatchQueue(
        label: "com.clipvault.sync.ostore.prefetch", qos: .utility, attributes: .concurrent
    )
    /// Peer high-water marks seen in the last ostore listing (panel lag without a cycle).
    private var ostorePeerRemote: [String: Int] = [:]
    /// `Last-Event-ID` across stream reconnects. nil = server decides (replay=0).
    private var ostoreCursor: UInt64?
    /// iCloud half runs on its own slower cadence even when ostore events drain fast.
    private var lastCloudCycleUnix: Double = 0
    /// Idle head rewrites are throttled: on `both` they would churn the File Provider.
    private var lastHeadWriteUnix: Double = 0
    /// iCloud peer scan cache. `buildStatus()` runs after every cycle, and on `both`
    /// an event cycle must not pay for reading the File Provider's heads each time.
    private var cloudPeers: [PeerStatus] = []
    private var lastCloudPeerScanUnix: Double = 0

    private init(database: DatabaseManager) {
        self.database = database
        self.config = Self.loadConfig()
        self.hostId = ClipHostIdentity.id
        if self.config.usesOstore {
            self.ostoreWire = OstoreSyncWire(prefix: self.config.ostorePrefix)
        }
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
            self.replayLocalOCRIfNeeded()
            self.startPollTimer()
            self.restartOstoreEvents(reason: "startup")
            if self.config.enabled {
                self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.cycle(reason: "startup")
                }
            }
            self.publishStatus()
            print("[Sync] ready · host=\(self.hostId) · enabled=\(self.config.enabled) · transport=\(self.config.transport) · poll=\(Int(self.config.pollIntervalSeconds))s · cloud=\(self.syncRootURL()?.path ?? "nil") · ostore=\(self.ostoreWire?.prefix ?? "nil")")
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
            var op = self.makeOp(
                kind: kind,
                itemId: itemId,
                item: item,
                blobKeys: keys.isEmpty ? blobs : keys
            )
            let sem = DispatchSemaphore(value: 0)
            var dailyCount = 1
            self.database.performSyncWork {
                dailyCount = self.database.captureCopyCountLocked(id: itemId)
                sem.signal()
            }
            sem.wait()
            op.copyCount = dailyCount
            self.enqueue(op)
            self.scheduleDrain(reason: "capture")
        }
    }

    /// OCR is derived after capture (image CAS is already on the wire). Follow-up
    /// upsert carries `ocr_text` only; `content_hash` stays the image blob.
    func recordLocalOCR(itemId: UUID, contentHash: String, ocrText: String, typeRaw: String = ClipboardType.image.rawValue, sourceApp: String? = nil) {
        guard config.enabled else { return }
        let text = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !contentHash.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.enqueueOCROp(
                itemId: itemId.uuidString,
                contentHash: contentHash,
                ocrText: text,
                typeRaw: typeRaw,
                sourceApp: sourceApp,
                drain: true
            )
        }
    }

    /// Sync-queue only. `drain: false` when the caller will schedule one drain for a batch.
    @discardableResult
    private func enqueueOCROp(
        itemId: String,
        contentHash: String,
        ocrText: String,
        typeRaw: String,
        sourceApp: String?,
        drain: Bool
    ) -> Int {
        var captureTs: Double?
        let sem = DispatchSemaphore(value: 0)
        database.performSyncWork {
            captureTs = self.database.captureTimestampLocked(id: itemId)
            sem.signal()
        }
        sem.wait()
        guard let wallTs = WallClockPolicy.wallTsForDerivedOp(captureTs: captureTs) else {
            print("[Sync] ocr skip, no capture clock id=\(itemId.prefix(8))")
            return 0
        }
        var op = makeOp(
            kind: "upsert",
            itemId: itemId,
            item: nil,
            blobKeys: nil,
            wallTs: wallTs
        )
        op.contentHash = contentHash
        op.type = typeRaw
        op.ocrText = ocrText
        op.textContent = nil
        op.htmlContent = nil
        op.sourceApp = sourceApp
        op.note = "ocr"
        enqueue(op)
        if drain {
            scheduleDrain(reason: "ocr")
            print("[Sync] ocr pack seq=\(op.seq) id=\(itemId.prefix(8)) chars=\(ocrText.count)")
        }
        return op.seq
    }

    /// One-shot: historical `ocr_text` lived only in local SQLite (capture trx raced Vision).
    /// Meta `sync.ocr_replay_v1` prevents re-emitting hundreds of follow-ups every launch.
    private func replayLocalOCRIfNeeded() {
        guard config.enabled else { return }
        let flag = "sync.ocr_replay_v1"
        let sem = DispatchSemaphore(value: 0)
        var already = false
        database.performSyncWork {
            already = self.database.metaGetSync(flag) == "1"
            sem.signal()
        }
        sem.wait()
        guard !already else { return }
        var rows: [DatabaseManager.OCRSyncPayload] = []
        database.performSyncWork {
            rows = self.database.listOCRPayloadsForSyncLocked()
            sem.signal()
        }
        sem.wait()
        var n = 0
        for row in rows {
            _ = enqueueOCROp(
                itemId: row.id.uuidString,
                contentHash: row.hash,
                ocrText: row.ocr,
                typeRaw: row.typeRaw,
                sourceApp: row.sourceApp,
                drain: false
            )
            n += 1
        }
        database.performSyncWork {
            self.database.metaSetSync(flag, "1")
            sem.signal()
        }
        sem.wait()
        print("[Sync] ocr replay packed n=\(n)")
        if n > 0 {
            scheduleDrain(reason: "ocr-replay")
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

    func recordLocalCompose(item: ClipboardItem, parentHash: String? = nil) {
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
            op.parentHash = parentHash
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
                self.restartOstoreEvents(reason: "enable")
                self.cycle(reason: "enable")
            } else {
                self.restartOstoreEvents(reason: "disable")
            }
            self.publishStatus()
            let c = self.config
            DispatchQueue.main.async { completion?(c) }
        }
    }

    /// Switch the wire from the panel/API: `clouddocs` | `ostore` | `both`.
    /// Rebinds the ostore wire (credentials may have appeared since launch) and
    /// resubscribes the stream. Invalid values are ignored, not persisted.
    func setTransport(_ transport: String, prefix: String? = nil, completion: ((Config) -> Void)? = nil) {
        let allowed: Set<String> = ["clouddocs", "ostore", "both"]
        queue.async { [weak self] in
            guard let self = self else { return }
            guard allowed.contains(transport) else {
                let c = self.config
                DispatchQueue.main.async { completion?(c) }
                return
            }
            self.config.transport = transport
            if let prefix, !prefix.isEmpty { self.config.ostorePrefix = prefix }
            Self.saveConfig(self.config)
            self.ostoreWire = self.config.usesOstore ? OstoreSyncWire(prefix: self.config.ostorePrefix) : nil
            self.ostoreCursor = nil
            self.restartOstoreEvents(reason: "transport")
            self.startPollTimer()
            if self.config.enabled { self.cycle(reason: "transport") }
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
    /// A cycle requested while one was running. Dropping it would leave the op sitting
    /// in ostore until the next 30 s poll — the classic "realtime" bug.
    private var pendingCycleReason: String?

    /// Coalesce a burst into one cycle. `delay` is the local-capture budget: with the
    /// ostore wire the whole point is sub-second publication, so the default shrinks
    /// from the iCloud-era 1.5 s to 150 ms. Installs on iCloud alone keep 1.5 s.
    private func scheduleDrain(reason: String, delay: Double? = nil) {
        drainWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.cycle(reason: reason)
        }
        drainWorkItem = work
        let wait = delay ?? (config.usesOstore ? 0.15 : 1.5)
        queue.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func cycle(reason: String, completion: ((Bool, String) -> Void)? = nil) {
        guard config.enabled else {
            completion?(false, "sync disabled")
            return
        }
        guard !inProgress else {
            pendingCycleReason = reason
            completion?(false, "sync in progress")
            return
        }
        inProgress = true
        lastPhase = "cycle:\(reason)"
        lastError = nil
        publishStatus()
        let t0 = Date().timeIntervalSince1970

        var messages: [String] = []
        var okAll = true
        var pushedTotal = 0
        var pulledTotal = 0

        // 1) ostore push runs first and never consumes the outbox: on `both` the
        //    iCloud push deletes op files on success, and the fast wire must not wait
        //    behind a dataless File Provider materialization.
        //
        //    An event-driven cycle is here to *pull* what a peer just published; it
        //    only pays for a push when local work is actually waiting.
        let eventDriven = (reason == "ostore-event" || reason == "ostore-blob")
        let pushDue = !eventDriven || outboxPendingCount() > 0
        if config.usesOstore && pushDue {
            lastPhase = "push:ostore"
            let tPush = Date().timeIntervalSince1970
            let pushed = ostorePush()
            messages.append(pushed.message)
            okAll = okAll && pushed.ok
            pushedTotal += pushed.n
            if pushed.ok { lastPushUnix = Date().timeIntervalSince1970 }
            UiMetrics.shared.emit(
                "sync_push",
                durMs: (Date().timeIntervalSince1970 - tPush) * 1000,
                ok: pushed.ok,
                payload: ["n": pushed.n, "reason": reason, "wire": "ostore"]
            )
        }

        // 2) Push local outbox (+ CAS) to iCloud Drive
        //
        // The iCloud half keeps its own slower cadence: ostore events drain every ~150 ms
        // and the File Provider does not need that. An event-driven drain still gives
        // iCloud a 5 s slice, and any non-event reason (poll / manual / startup) always
        // runs it.
        // On `both`, iCloud is the compatibility wire: it must not steal the realtime
        // path. A File Provider cycle can spend seconds on a dataless head, and it
        // shares this serial queue with the ostore pull, so it only runs on its own
        // cadence (poll / startup / manual switches), never on a capture or an event.
        // A `clouddocs`-only install keeps the old behaviour exactly.
        let nowUnix = Date().timeIntervalSince1970
        let cloudReason: Set<String> = ["poll", "startup", "manual", "enable", "transport", "ostore-reset"]
        let cloudDue = config.usesCloudDocs && (!config.usesOstore || cloudReason.contains(reason))
        if cloudDue { lastCloudCycleUnix = nowUnix }
        if cloudDue {
            lastPhase = "push"
            let tPush = Date().timeIntervalSince1970
            let pushed = pushOutbox()
            messages.append(pushed.message)
            okAll = okAll && pushed.ok
            pushedTotal += pushed.n
            if pushed.ok { lastPushUnix = Date().timeIntervalSince1970 }
            UiMetrics.shared.emit(
                "sync_push",
                durMs: (Date().timeIntervalSince1970 - tPush) * 1000,
                ok: pushed.ok,
                payload: ["n": pushed.n, "reason": reason, "wire": "clouddocs"]
            )
        }

        // 3) Pull remote ops (ostore first: it is the low-latency wire; the cursor is shared)
        if config.usesOstore {
            lastPhase = "pull:ostore"
            let tPull = Date().timeIntervalSince1970
            let pulled = ostorePull(reason: reason)
            messages.append(pulled.message)
            okAll = okAll && pulled.ok
            pulledTotal += pulled.n
            if pulled.ok { lastPullUnix = Date().timeIntervalSince1970 }
            UiMetrics.shared.emit(
                "sync_pull",
                durMs: (Date().timeIntervalSince1970 - tPull) * 1000,
                ok: pulled.ok,
                payload: ["n": pulled.n, "reason": reason, "wire": "ostore"]
            )
        }
        if cloudDue {
            lastPhase = "pull"
            let tPull = Date().timeIntervalSince1970
            let pulled = pullRemote()
            messages.append(pulled.message)
            okAll = okAll && pulled.ok
            pulledTotal += pulled.n
            if pulled.ok { lastPullUnix = Date().timeIntervalSince1970 }
            UiMetrics.shared.emit(
                "sync_pull",
                durMs: (Date().timeIntervalSince1970 - tPull) * 1000,
                ok: pulled.ok,
                payload: ["n": pulled.n, "reason": reason, "wire": "clouddocs"]
            )
        }

        lastPhase = okAll ? "ok" : "partial"
        if !okAll, lastError == nil {
            lastError = messages.joined(separator: " · ")
        }
        inProgress = false
        publishStatus()
        UiMetrics.shared.emit(
            "sync_cycle",
            durMs: (Date().timeIntervalSince1970 - t0) * 1000,
            ok: okAll,
            payload: ["n": pushedTotal + pulledTotal, "reason": reason]
        )
        let st = buildStatus()
        // Outbox backlog is a value, not a duration.
        UiMetrics.shared.emit(
            "sync_queue_depth",
            value: Double(st.outboxPending),
            ok: st.outboxPending == 0,
            payload: ["n": st.peers.count]
        )
        // One row per cycle (worst peer), not one per peer — lag is a value, not a duration.
        if let worst = st.peers.max(by: { $0.lag < $1.lag }) {
            UiMetrics.shared.emit(
                "sync_peer_lag",
                value: Double(worst.lag),
                ok: worst.lag == 0,
                payload: [
                    "n": st.peers.count,
                    "host": String(worst.host.prefix(8)),
                ]
            )
        }
        completion?(okAll, messages.joined(separator: " · "))
        // Run again immediately: something asked for a cycle while this one owned the
        // queue (a peer event that arrived mid-pull).
        if let next = pendingCycleReason {
            pendingCycleReason = nil
            queue.async { [weak self] in self?.cycle(reason: next) }
        }
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

    private func makeOp(kind: String, itemId: String, item: ClipboardItem?, blobKeys: [String]?, wallTs: Double? = nil) -> SyncOp {
        let seq = nextSeq
        nextSeq += 1
        persistNextSeq()
        let wall = wallTs ?? item?.timestamp.timeIntervalSince1970 ?? Date().timeIntervalSince1970
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
        var n: Int = 0
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
            // Still refresh head so peers see liveness. Throttled: on `both` an
            // ostore-driven drain can fire every 150 ms and must not churn iCloud.
            let now = Date().timeIntervalSince1970
            if now - lastHeadWriteUnix >= 10 {
                lastHeadWriteUnix = now
                writeHead(seq: max(0, nextSeq - 1), lastOpId: nil, root: syncRoot)
            }
            return StepResult(ok: true, message: "push:idle", n: 0)
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
        return StepResult(ok: true, message: "push:\(published)", n: published)
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

    // MARK: ostore transport
    //
    // Same trx log, different wire. Discovery is **one** `list` per cycle (trx, attach
    // and heads share the prefix), publishing is one `POST /api/batch` per chunk, and
    // the SSE stream turns "a peer published" into a drain in ~150 ms.

    private func ostoreWireOrNil() -> OstoreSyncWire? {
        if let w = ostoreWire { return w }
        guard config.usesOstore, let w = OstoreSyncWire(prefix: config.ostorePrefix) else { return nil }
        ostoreWire = w
        return w
    }

    private struct OstoreIndex {
        var objects: [String: OstoreSyncWire.Entry] = [:]
        var trxMaxSeq: [String: Int] = [:]
    }

    /// Authoritative catch-up: one listing of the whole sync prefix.
    ///
    /// This is the *slow* path (startup, `stream.reset`, periodic poll). Event-driven
    /// cycles never call it: the event already named the peer and the seq, so pulling
    /// one op costs one GET, and a recursive listing over a growing log never becomes
    /// the per-capture cost.
    private func ostoreIndex(_ wire: OstoreSyncWire, checksums: Bool) throws -> OstoreIndex {
        var idx = OstoreIndex()
        for entry in try wire.list(checksums: checksums) where entry.type == "file" {
            idx.objects[entry.path] = entry
            if let t = wire.parseTrxPath(entry.path) {
                idx.trxMaxSeq[t.host] = max(idx.trxMaxSeq[t.host] ?? 0, t.seq)
            }
        }
        // Authoritative: a peer whose log was pruned must disappear, or it would be
        // probed for a 404 on every cycle forever.
        ostorePeerRemote = idx.trxMaxSeq
        return idx
    }

    private func pendingOutboxOps() -> [(op: SyncOp, url: URL)] {
        let files = ((try? fm.contentsOfDirectory(
            at: outboxDir(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var out: [(SyncOp, URL)] = []
        for f in files {
            guard let data = try? Data(contentsOf: f),
                  let op = try? decoder.decode(SyncOp.self, from: data) else { continue }
            out.append((op, f))
        }
        return out
    }

    private enum OstoreUpload {
        case inline(Data)
        case file(URL)
    }

    private static func fileMD5(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = Insecure.MD5()
        while true {
            let chunk = h.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Publish outbox ops + their attachments. Attachments always go **before** the
    /// trx object that names them: a peer reacts to the trx event, so the bytes must
    /// already be visible when the event fires.
    private func ostorePush() -> StepResult {
        guard let wire = ostoreWireOrNil() else {
            lastError = "ostore 未配置（config/ostore-backup.json）"
            return StepResult(ok: false, message: "push:ostore no_config")
        }
        let ops = pendingOutboxOps()
        if ops.isEmpty {
            // Idle: refresh the head so peers can see liveness, but not on every
            // event-driven tick — one PUT per 30 s is plenty.
            let now = Date().timeIntervalSince1970
            if now - lastHeadWriteUnix >= 30 {
                lastHeadWriteUnix = now
                writeOstoreHead(wire: wire, seq: max(0, nextSeq - 1), lastOpId: nil)
            }
            return StepResult(ok: true, message: "push:ostore idle", n: 0)
        }
        var plan: [(path: String, payload: OstoreUpload, md5: String)] = []
        var skipped = 0
        for (op, _) in ops {
            for key in op.blobKeys ?? [] {
                let local = database.blobFileURL(hash: key)
                guard fm.fileExists(atPath: local.path) else {
                    lastError = "blob missing local \(key)"
                    return StepResult(ok: false, message: "push:ostore blob_missing \(key)")
                }
                let path = wire.attachedPath(key: key)
                if publishedAttachments.contains(key) { skipped += 1; continue }
                // Attachments are content-addressed: the path *is* the digest, so a
                // 200 on stat means the bytes are already there — no checksum needed.
                if (try? wire.exists(path: path)) == true {
                    publishedAttachments.insert(key)
                    skipped += 1
                    continue
                }
                let sum = Self.fileMD5(local) ?? ""
                let size = (try? fm.attributesOfItem(atPath: local.path)[.size] as? Int) ?? 0
                if size > 2 * 1024 * 1024 {
                    plan.append((path, .file(local), sum))
                } else {
                    guard let data = try? Data(contentsOf: local) else {
                        lastError = "blob unreadable \(key)"
                        return StepResult(ok: false, message: "push:ostore blob_unreadable \(key)")
                    }
                    plan.append((path, .inline(data), sum))
                }
            }
        }
        // The trx object is one file per seq, written once. Re-PUT after a crash is
        // idempotent, so no existence probe is worth a round trip here.
        for (op, file) in ops {
            guard let data = try? Data(contentsOf: file) else { continue }
            let path = wire.trxPath(host: op.host, seq: op.seq)
            plan.append((path, .inline(data), OstoreSyncWire.md5Hex(data)))
        }
        var published = 0
        do {
            published = try publishPlan(plan, wire: wire)
        } catch {
            lastError = "ostore upload: \(error.localizedDescription)"
            return StepResult(ok: false, message: "push:ostore upload_fail")
        }
        for (op, _) in ops { for key in op.blobKeys ?? [] { publishedAttachments.insert(key) } }
        // The head is a liveness/seq hint, not part of the protocol: peers learn the
        // seq from the trx event itself. Rewriting it after every push would add a
        // whole round trip to the capture path for nothing.
        let highest = max(ops.map(\.op.seq).max() ?? 0, max(0, nextSeq - 1))
        let nowUnix = Date().timeIntervalSince1970
        if nowUnix - lastHeadWriteUnix >= 10 {
            lastHeadWriteUnix = nowUnix
            writeOstoreHead(wire: wire, seq: highest, lastOpId: ops.last?.op.opId)
        }
        // On `both` the iCloud push owns outbox deletion; alone, we retire the files.
        if !config.usesCloudDocs {
            for (_, file) in ops { try? fm.removeItem(at: file) }
        }
        return StepResult(
            ok: true,
            message: plan.isEmpty ? "push:ostore idle" : "push:ostore +\(published)/=\(skipped)",
            n: published
        )
    }

    /// Inline JSON rides `POST /api/batch` (one RTT for a burst); large attachments
    /// stream with their own PUT. A server without `/api/batch` is detected once and
    /// every object then falls back to PUT.
    private func publishPlan(
        _ plan: [(path: String, payload: OstoreUpload, md5: String)],
        wire: OstoreSyncWire
    ) throws -> Int {
        var published = 0
        var chunk: [OstoreSyncWire.BatchItem] = []
        var bytes = 0

        func verify(_ path: String, _ reply: OstoreSyncWire.PutReply, _ expected: String) throws {
            // `sha256` on some ostore builds is actually MD5; only `md5` is trustworthy.
            if let got = reply.md5, got.lowercased() != expected {
                throw OstoreSyncWire.WireError(message: "ostore 校验失败 \(path)")
            }
        }
        func flush() throws {
            guard !chunk.isEmpty else { return }
            let items = chunk
            chunk.removeAll()
            bytes = 0
            if let reply = try wire.batch(items) {
                for item in items {
                    if let err = reply.failed[item.path] {
                        throw OstoreSyncWire.WireError(message: "ostore 批量失败 \(item.path): \(err)")
                    }
                    guard let row = reply.written[item.path] else {
                        throw OstoreSyncWire.WireError(message: "ostore 批量无回执 \(item.path)")
                    }
                    try verify(item.path, row, OstoreSyncWire.md5Hex(item.data))
                    published += 1
                }
                return
            }
            for item in items {
                let reply = try wire.put(path: item.path, data: item.data)
                try verify(item.path, reply, OstoreSyncWire.md5Hex(item.data))
                published += 1
            }
        }

        for entry in plan {
            switch entry.payload {
            case .inline(let data):
                if chunk.count >= OstoreSyncWire.batchMaxObjects
                    || bytes + data.count > OstoreSyncWire.batchMaxBytes {
                    try flush()
                }
                chunk.append(OstoreSyncWire.BatchItem(path: entry.path, data: data))
                bytes += data.count
            case .file(let url):
                try flush()
                let reply = try wire.putFile(path: entry.path, file: url)
                try verify(entry.path, reply, entry.md5)
                published += 1
            }
        }
        try flush()
        return published
    }

    private func writeOstoreHead(wire: OstoreSyncWire, seq: Int, lastOpId: String?) {
        let head = HostHead(
            host: hostId,
            seq: seq,
            lastOpId: lastOpId,
            wallTs: Date().timeIntervalSince1970,
            itemHint: nil,
            updatedAt: ClipTimeFormat.isoLocal()
        )
        guard let data = try? encoder.encode(head) else { return }
        do {
            _ = try wire.put(path: wire.headPath(host: hostId), data: data)
        } catch {
            print("[Sync] ostore head write failed: \(error.localizedDescription)")
        }
    }

    /// Pull every peer's log forward over ostore. Cursor, merge rules and
    /// notifications are the same as the iCloud path — only bytes on the wire differ.
    private func ostorePull(reason: String) -> StepResult {
        guard let wire = ostoreWireOrNil() else {
            return StepResult(ok: false, message: "pull:ostore no_config")
        }
        // Fast path: the event already named the peer and its seq, so a capture costs
        // one GET per op. Only startup / reset / periodic poll pays for the listing.
        let fromEvents = (reason == "ostore-event" || reason == "ostore-blob")
        var peers: [String: Int] = [:]
        if fromEvents && !ostorePeerRemote.isEmpty {
            peers = ostorePeerRemote
        } else {
            do {
                peers = try ostoreIndex(wire, checksums: false).trxMaxSeq
            } catch {
                lastError = "ostore list: \(error.localizedDescription)"
                return StepResult(ok: false, message: "pull:ostore list_fail")
            }
        }
        var appliedTotal = 0
        var blobWaits = 0
        var applyByKind: [String: (ok: Int, fail: Int)] = [:]
        var notes: [String] = []

        for host in peers.keys.sorted() where host != hostId {
            let remote = peers[host] ?? 0
            peerRemoteSeq[host] = remote
            var cursor = appliedSeq(for: host)
            var batch = 0
            while cursor < remote, batch < config.pullBatchLimit {
                let next = cursor + 1
                let path = wire.trxPath(host: host, seq: next)
                let fetched: Data?
                do {
                    fetched = try wire.getIfPresent(path: path)
                } catch {
                    lastError = "ostore get op: \(error.localizedDescription)"
                    break
                }
                guard let data = fetched else {
                    // Not there yet: a partial push, or an event that beat the object.
                    lastPhase = "pull:ostore gap \(host)#\(next)"
                    break
                }
                guard let op = try? decoder.decode(SyncOp.self, from: data) else {
                    lastError = "ostore op decode \(host)#\(next)"
                    break
                }
                if let keys = op.blobKeys, !keys.isEmpty {
                    var missing = false
                    for key in keys {
                        // A prefetch is already pulling these bytes: wait for it instead
                        // of buying a second round trip. Bounded, so a stuck download
                        // falls through to the blob-wait retry.
                        if prefetching.contains(key) {
                            for _ in 0..<100 where database.readBlobFile(hash: key) == nil {
                                Thread.sleep(forTimeInterval: 0.02)
                            }
                        }
                        if database.readBlobFile(hash: key) != nil { continue }
                        guard needsBlob(op: op, key: key) else { continue }
                        do {
                            if let blob = try wire.getIfPresent(path: wire.attachedPath(key: key)) {
                                if !database.writeBlobFile(hash: key, data: blob) { missing = true }
                            } else {
                                missing = true
                            }
                        } catch {
                            missing = true
                        }
                        if missing {
                            blobWaits += 1
                            lastPhase = "pull:ostore blob_wait \(key)"
                        }
                    }
                    if missing { break }
                }
                let outcome = applyPulledOp(op, host: host, seq: next)
                var stat = applyByKind[op.kind] ?? (ok: 0, fail: 0)
                if outcome.ok { stat.ok += 1 } else { stat.fail += 1 }
                applyByKind[op.kind] = stat
                if !outcome.ok {
                    lastPhase = "pull:ostore retry \(op.kind) \(op.itemId.prefix(8))"
                    break
                }
                if op.kind == "web_archive" {
                    hydrateArchiveDependents(
                        htmlSHA: op.contentHash ?? op.blobKeys?.first,
                        listed: op.blobKeys
                    )
                }
                cursor = next
                appliedTotal += 1
                batch += 1
                if outcome.changed { notifyIngested(op) }
            }
            notes.append("\(host)+\(batch)/@\(cursor)")
        }

        if blobWaits > 0 {
            UiMetrics.shared.emit("sync_blob_wait", ok: false, payload: ["n": blobWaits, "wire": "ostore"])
            // Bytes lagged the trx event (or the GET failed): come back for them soon
            // instead of waiting a whole poll interval.
            scheduleDrain(reason: "ostore-blob", delay: 0.6)
        }
        for (kind, stat) in applyByKind {
            UiMetrics.shared.emit(
                "sync_apply",
                ok: stat.fail == 0,
                payload: ["kind": kind, "n": stat.ok, "wire": "ostore"]
            )
        }
        return StepResult(
            ok: true,
            message: "pull:ostore \(appliedTotal) [\(notes.joined(separator: ","))]",
            n: appliedTotal
        )
    }

    // MARK: ostore event stream

    /// (Re)subscribe to the store's object events. The stream only *triggers* a pull;
    /// listing/cursors stay authoritative, so a missed or replayed event costs latency,
    /// never correctness.
    private func restartOstoreEvents(reason: String) {
        ostoreWire?.stopEvents()
        guard config.enabled, config.usesOstore, let wire = ostoreWireOrNil() else {
            noteOstoreStream(connected: false)
            return
        }
        wire.startEvents(
            since: ostoreCursor,
            onEvent: { [weak self] ev in
                guard let self else { return }
                self.queue.async { self.handleOstoreEvent(ev, wire: wire) }
            },
            onReset: { [weak self] in
                guard let self else { return }
                self.ostoreCursor = nil
                self.queue.async { self.cycle(reason: "ostore-reset") }
            },
            onState: { [weak self] up in
                guard let self else { return }
                self.queue.async { self.noteOstoreStream(connected: up) }
            }
        )
        print("[Sync] ostore stream · \(wire.baseHost)/\(wire.prefix) · reason=\(reason)")
    }

    private func handleOstoreEvent(_ ev: OstoreSyncWire.ObjectEvent, wire: OstoreSyncWire) {
        if let id = ev.id { ostoreCursor = id }
        guard wire.matchesPrefix(ev.path) else { return }
        ostoreLastEventUnix = Date().timeIntervalSince1970
        if ev.kind == "object.deleted" {
            // The log was pruned out of band: the cursor can no longer be trusted.
            cycle(reason: "ostore-delete")
            return
        }
        if let t = wire.parseTrxPath(ev.path), t.host != hostId {
            ostorePeerRemote[t.host] = max(ostorePeerRemote[t.host] ?? 0, t.seq)
            scheduleDrain(reason: "ostore-event", delay: 0.15)
            return
        }
        // Attachment events are a head start, not extra work: fetch the blob now, in
        // parallel with the trx GET that will name it. On a 500 ms RTT a sequential
        // pair already costs a second of the 3 s budget.
        let attachPrefix = wire.prefix + "/attach/"
        if ev.path.hasPrefix(attachPrefix), ev.path.hasSuffix(".bin") {
            prefetchAttachment(key: String(ev.path.dropFirst(attachPrefix.count).dropLast(4)),
                               path: ev.path, wire: wire)
        }
    }

    /// Download one attachment in the background, ahead of the trx that names it.
    /// Content-addressed: the digest is re-verified before it lands in the CAS.
    private func prefetchAttachment(key: String, path: String, wire: OstoreSyncWire) {
        guard !key.isEmpty, !key.contains("/") else { return }
        guard database.readBlobFile(hash: key) == nil else { return }
        guard !prefetching.contains(key) else { return }
        prefetching.insert(key)
        prefetchQueue.async { [weak self] in
            guard let self else { return }
            defer { self.queue.async { self.prefetching.remove(key) } }
            guard let data = try? wire.getIfPresent(path: path), !data.isEmpty else { return }
            guard OstoreSyncWire.sha256Hex(data) == key else {
                print("[Sync] ostore attach digest mismatch \(key.prefix(8)) — dropped")
                return
            }
            _ = self.database.writeBlobFile(hash: key, data: data)
        }
    }

    private func noteOstoreStream(connected: Bool) {
        guard ostoreConnected != connected else { return }
        ostoreConnected = connected
        if !connected { lastPhase = "ostore:stream_down" }
        startPollTimer()
        publishStatus()
        print("[Sync] ostore stream \(connected ? "up" : "down") · poll \(Int(pollInterval()))s")
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
        var applyByKind: [String: (ok: Int, fail: Int)] = [:]
        var blobWaits = 0
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
                            blobWaits += 1
                            break
                        }
                    }
                    if keys.contains(where: { database.readBlobFile(hash: $0) == nil && needsBlob(op: op, key: $0) }) {
                        blobWaits += 1
                        break
                    }
                }

                let outcome = applyPulledOp(op, host: head.host, seq: next)
                var kindStat = applyByKind[op.kind] ?? (ok: 0, fail: 0)
                if outcome.ok { kindStat.ok += 1 } else { kindStat.fail += 1 }
                applyByKind[op.kind] = kindStat
                if !outcome.ok {
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
                if outcome.changed { notifyIngested(op) }
            }
            appliedTotal += applied
            peerNotes.append("\(head.host)+\(applied)/@\(cursor)")
        }

        if blobWaits > 0 {
            UiMetrics.shared.emit("sync_blob_wait", ok: false, payload: ["n": blobWaits])
        }
        for (kind, stat) in applyByKind {
            UiMetrics.shared.emit(
                "sync_apply",
                ok: stat.fail == 0,
                payload: ["kind": kind, "n": stat.ok]
            )
        }
        return StepResult(ok: true, message: "pull:\(appliedTotal) [\(peerNotes.joined(separator: ","))]", n: appliedTotal)
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

    private func applyPulledOp(_ op: SyncOp, host: String, seq: Int) -> (ok: Bool, changed: Bool) {
        let sem = DispatchSemaphore(value: 0)
        var changed = false
        var appliedOk = false
        database.performSyncWork {
            changed = self.applyOpLocked(op)
            appliedOk = changed || self.applyIsIdempotentSuccess(op)
            if appliedOk {
                self.database.metaSetSync(self.appliedKey(host: host), String(seq))
            }
            sem.signal()
        }
        sem.wait()
        return (appliedOk, changed)
    }

    /// One notification shape for every wire: capture kinds carry the item id so the
    /// wall ingests a single card; judgment kinds stay id-less (cheap head merge).
    private func notifyIngested(_ op: SyncOp) {
        let capture = (op.kind == "upsert" || op.kind == "compose" || op.kind == "touch")
        NotificationCenter.default.post(
            name: Notification.Name("ClipVaultItemAdded"),
            object: capture ? op.itemId : nil
        )
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
                source: "sync:\(op.host)",
                parentHash: op.parentHash
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
                copyCount: op.copyCount ?? 1,
                bumpTimestamp: WallClockPolicy.bumpTimestamp(forKind: op.kind)
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
            // Decode OFF dbQueue: reading thousands of trx files on the writer queue was
            // the multi-second db_write(kind=queue) stall during startup replay.
            var ops: [SyncOp] = []
            for url in files {
                guard let data = try? Data(contentsOf: url),
                      let op = try? decoder.decode(SyncOp.self, from: data),
                      op.kind == "reader_op" else { continue }
                ops.append(op)
            }
            guard !ops.isEmpty else { return }
            // Apply in small chunks so captures/writes interleave between blocks.
            for start in stride(from: 0, to: ops.count, by: 200) {
                let slice = Array(ops[start..<min(start + 200, ops.count)])
                self.database.performSyncWork {
                    var n = 0
                    for op in slice where self.applyOpLocked(op) { n += 1 }
                    if n > 0 { print("[Sync] replayDiskReaderOps applied \(n)") }
                }
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
            // Parse OFF dbQueue (file read + JSON), then apply on it.
            var links: [(opId: String, ts: Double, action: String, fromId: String, toItemId: String?, toHash: String?, toIsNote: Bool, kind: String, pairKey: String, host: String)] = []
            for url in files {
                guard let data = try? Data(contentsOf: url),
                      let op = try? decoder.decode(SyncOp.self, from: data),
                      op.kind == "clip_link" else { continue }
                guard let raw = op.note, let noteData = raw.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: noteData) as? [String: Any] else {
                    continue
                }
                links.append((
                    opId: op.opId, ts: op.wallTs,
                    action: (obj["action"] as? String) ?? "",
                    fromId: (obj["from_item_id"] as? String) ?? op.itemId,
                    toItemId: obj["to_item_id"] as? String,
                    toHash: (obj["to_content_hash"] as? String) ?? op.contentHash,
                    toIsNote: DatabaseManager.jsonFlag(obj["to_is_note"]),
                    kind: (obj["kind"] as? String) ?? "related",
                    pairKey: (obj["pair_key"] as? String) ?? "",
                    host: op.host
                ))
            }
            guard !links.isEmpty else { return }
            self.database.performSyncWork {
                var n = 0
                var pairKeys = Set<String>()
                var itemIds = Set<String>()
                var hashes = Set<String>()
                for l in links {
                    if let key = self.database.ingestClipLinkReplayLocked(
                        opId: l.opId,
                        ts: l.ts,
                        action: l.action,
                        fromItemId: l.fromId,
                        toContentHash: l.toHash,
                        toItemId: l.toItemId,
                        toIsNote: l.toIsNote,
                        kind: l.kind,
                        pairKey: l.pairKey,
                        source: "replay:\(l.host)"
                    ) {
                        n += 1
                        pairKeys.insert(key)
                        itemIds.insert(UUID(uuidString: l.fromId)?.uuidString ?? l.fromId)
                        if let toItemId = l.toItemId { itemIds.insert(UUID(uuidString: toItemId)?.uuidString ?? toItemId) }
                        if let toHash = l.toHash { hashes.insert(toHash.lowercased()) }
                    }
                }
                self.database.finishClipLinkReplayLocked(pairKeys: pairKeys, itemIds: itemIds, hashes: hashes)
                if n > 0 { print("[Sync] replayDiskClipLinks applied \(n)") }
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

    /// Cadence is transport-aware: the iCloud plane is polled (45 s by default), while
    /// an ostore install rides its event stream and falls back to a 2 s poll when the
    /// stream is down so the 3 s realtime budget still holds.
    private func pollInterval() -> Double {
        guard config.usesOstore else { return max(15, config.pollIntervalSeconds) }
        return ostoreConnected
            ? max(5, config.ostoreOnlinePollSeconds)
            : max(1, config.ostoreOfflinePollSeconds)
    }

    private func startPollTimer() {
        pollTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = pollInterval()
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
        let nowUnix = Date().timeIntervalSince1970
        if config.usesCloudDocs, let root,
           cloudPeers.isEmpty || nowUnix - lastCloudPeerScanUnix >= 15 {
            var scanned: [PeerStatus] = []
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
                scanned.append(PeerStatus(
                    host: head.host,
                    remoteSeq: max(head.seq, diskMax),
                    appliedSeq: applied,
                    lag: max(0, head.seq - applied)
                ))
            }
            cloudPeers = scanned
            lastCloudPeerScanUnix = nowUnix
        }
        if config.usesCloudDocs { peers.append(contentsOf: cloudPeers) }
        if config.usesOstore {
            for (host, remote) in ostorePeerRemote where host != hostId {
                let applied = appliedSeq(for: host)
                peers.append(PeerStatus(
                    host: host,
                    remoteSeq: remote,
                    appliedSeq: applied,
                    lag: max(0, remote - applied)
                ))
            }
        }
        // One row per peer: on `both` a host shows up on each wire.
        var byHost: [String: PeerStatus] = [:]
        for p in peers {
            if let old = byHost[p.host] {
                byHost[p.host] = PeerStatus(
                    host: p.host,
                    remoteSeq: max(old.remoteSeq, p.remoteSeq),
                    appliedSeq: max(old.appliedSeq, p.appliedSeq),
                    lag: min(old.lag, p.lag)
                )
            } else {
                byHost[p.host] = p
            }
        }
        let wireName: String
        switch config.transport {
        case "ostore": wireName = "tx+ostore"
        case "both": wireName = "tx+ostore+cloud"
        default: wireName = "tx+cloud"
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
            peers: byHost.values.sorted { $0.host < $1.host },
            pollIntervalSeconds: pollInterval(),
            scheme: wireName,
            policy: "per-host trx/ · \(config.transport) wire · eventual consistency · \(config.usesOstore ? (ostoreConnected ? "sse + " : "poll + ") : "")poll \(Int(pollInterval()))s · never whole-db replace",
            transport: config.transport,
            ostorePrefix: config.usesOstore ? config.ostorePrefix : nil,
            ostoreBaseHost: config.usesOstore ? ostoreWire?.baseHost : nil,
            ostoreConnected: ostoreConnected,
            ostoreLastEventUnix: ostoreLastEventUnix
        )
    }

    private func publishStatus() {
        NotificationCenter.default.post(name: Self.statusChangedNotification, object: nil)
    }
}
