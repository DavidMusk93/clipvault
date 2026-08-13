import Foundation
import CryptoKit
import Darwin
import SQLite3

/// Personal-machine SOTA backup to **iCloud Drive (CloudDocs)** — no App iCloud entitlements.
///
/// ## Strategy (sqlite-runtime-tricks aligned)
/// - **latest/clipflow.db** — slim SQLite (metadata; blobs externalized) via `sqlite3_backup`.
/// - **blobs/{hash}.bin** — content-addressed CAS at backup root (sync only missing files).
/// - **snapshots/** — sparse **db-only** history (small); blobs shared via CAS.
/// - SHA256 of db → skip promote when unchanged; prune keep=3; scrub `.tmp_*`.
/// - One-shot cleanup of legacy DuckDB under CloudDocs/ClipFlow/db.
///
/// ```
/// …/CloudDocs/ClipFlow/backup/
///   latest/{clipflow.db, MANIFEST.json}
///   blobs/{sha256}.bin
///   snapshots/YYYYMMDD-HHmmss/{clipflow.db, MANIFEST.json}
///   STATUS.json
/// ```
/// Local config: `~/Documents/ClipFlow/config/backup.json`
final class CloudDocsBackupService {
    /// Set once from `main` via `bootstrap(database:)`.
    private(set) static var shared: CloudDocsBackupService?

    static let itemAddedNotification = Notification.Name("ClipFlowItemAdded")
    static let statusChangedNotification = Notification.Name("ClipFlowBackupStatusChanged")

    @discardableResult
    static func bootstrap(database: DatabaseManager) -> CloudDocsBackupService {
        if let s = shared { return s }
        let s = CloudDocsBackupService(database: database)
        shared = s
        return s
    }

    /// Minute-level cadence + tight version budget + multi-destination fan-out.
    struct Config: Codable, Equatable {
        var enabled: Bool = true
        /// Named history dirs under snapshots/ (not counting latest/) — keep small: each is full db.
        var keepSnapshots: Int = 3
        /// Coalesce bursty clip writes before starting a backup
        var throttleSeconds: Double = 60
        /// Min gap between successive **latest** updates
        var minIntervalSeconds: Double = 60
        /// If still dirty, force latest update at least this often
        var maxIntervalSeconds: Double = 300
        /// Min gap between **named snapshots** (sparse history) — default 30min
        var snapshotEverySeconds: Double = 1800
        /// Fan-out targets (iCloud / Google Drive / custom folder).
        var destinations: [BackupDestinationConfig] = BackupDestinationConfig.defaultList
        static let `default` = Config()
    }

    struct Manifest: Codable {
        var version: Int = 3
        var createdAt: String
        var createdAtUnix: Double
        var sourcePath: String
        var byteSize: Int
        var sha256: String
        var itemCount: Int?
        var engine: String = "sqlite3_backup+cas_blobs"
        var host: String
        var note: String?
        var blobCount: Int? = nil
        var blobBytes: Int? = nil
        /// CAS filenames present under `blobs/` when this manifest was published.
        /// Clients use this to detect incomplete Drive listings (count/names).
        var blobFiles: [String]? = nil
        /// True only after local dest blob sizes were verified against source CAS.
        var blobsVerified: Bool? = nil
    }

    struct SnapshotInfo: Codable {
        var id: String
        var path: String
        var createdAt: String?
        var byteSize: Int?
        var sha256: String?
        var itemCount: Int?
        var isLatest: Bool
    }

    struct Status: Codable {
        var enabled: Bool
        var cloudDocsAvailable: Bool
        var cloudDocsPath: String?
        var backupRootPath: String?
        var lastSuccessAt: String?
        var lastSuccessUnix: Double?
        var lastError: String?
        var lastPhase: String?
        var inProgress: Bool
        var dirty: Bool
        var latest: SnapshotInfo?
        var snapshots: [SnapshotInfo]
        var config: Config
        var scheme: String = "multi"
        var requiresAppEntitlement: Bool = false
        /// Human policy summary for UI
        var policy: String = ""
        var lastSnapshotAt: String? = nil
        var lastSnapshotUnix: Double? = nil
        var snapshotCount: Int = 0
        /// Per-destination health (iCloud / Google Drive / …)
        var destinations: [BackupDestinationStatus] = []
        /// Auto-probed Quark client + staging (path never requires manual browse).
        var quarkDiscovery: QuarkDiscoveryReport? = nil
        var googleDriveAvailable: Bool = false
        var googleDrivePath: String? = nil
    }

    private let database: DatabaseManager
    private let queue = DispatchQueue(label: "com.clipflow.backup.clouddocs", qos: .utility)
    private let fm = FileManager.default

    private var config: Config
    private var dirty = false
    private var inProgress = false
    private var lastSuccessUnix: Double?
    private var lastError: String?
    private var lastPhase: String?
    private var throttleWorkItem: DispatchWorkItem?
    private var maxIntervalTimer: DispatchSourceTimer?
    private var lastContentFingerprint: String?
    private var lastSnapshotUnix: Double?
    /// Per-destination last outcome (in-memory; also mirrored into STATUS.json).
    private var destLastSuccessUnix: [String: Double] = [:]
    private var destLastError: [String: String] = [:]
    private var destLastPhase: [String: String] = [:]

    private init(database: DatabaseManager) {
        self.database = database
        self.config = Self.loadConfig()
        self.migrateConfigIfNeeded()
        self.config.destinations = BackupDestinationResolver.normalizeDestinations(self.config.destinations)
        // Never enumerate CloudDocs on the main/init path: File Provider can block
        // `contentsOfDirectory` for tens of seconds under launchd, which stalls
        // WebServer bind and looks like a dead daemon.
        self.lastSnapshotUnix = nil
        NotificationCenter.default.addObserver(
            forName: Self.itemAddedNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.markDirty(reason: "item_added")
        }
        startMaxIntervalWatchdog()
        // Resolve last snapshot + prune off the critical path (iCloud may stall).
        queue.async { [weak self] in
            guard let self = self else { return }
            self.lastSnapshotUnix = self.newestSnapshotUnix()
            self.pruneSnapshots(keep: self.config.keepSnapshots)
            self.publishStatus()
            self.scrubLegacyArtifacts()
        }
        if config.enabled {
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.markDirty(reason: "startup")
            }
        }
        // Path string only — do not touch CloudDocs listing here.
        let rootHint = BackupDestinationResolver.cloudDocsURL()?.appendingPathComponent("ClipFlow/backup").path
            ?? "(CloudDocs pending)"
        print("[Backup] CloudDocs ready · enabled=\(config.enabled) · keep=\(config.keepSnapshots) · latest≥\(Int(config.minIntervalSeconds))s · snap≥\(Int(config.snapshotEverySeconds))s · root=\(rootHint)")
    }

    /// Tighten chatty early defaults (keep=20, throttle=3s) to minute-level policy.
    private func migrateConfigIfNeeded() {
        var c = config
        var changed = false
        // Old defaults were keep=20 / throttle=3 / min=30 / max=900
        if c.keepSnapshots > 8 {
            c.keepSnapshots = 5
            changed = true
        }
        if c.throttleSeconds < 30 {
            c.throttleSeconds = 60
            changed = true
        }
        if c.minIntervalSeconds < 45 {
            c.minIntervalSeconds = 60
            changed = true
        }
        if c.maxIntervalSeconds > 600 || c.maxIntervalSeconds < c.minIntervalSeconds {
            c.maxIntervalSeconds = 300
            changed = true
        }
        // snapshotEverySeconds may be missing in old JSON → decode uses 0 for missing Double? 
        // With default in struct, missing key gets 0 for non-optional without custom decode...
        // Actually Codable synthesizes: missing key fails entire decode OR uses default only with init(from) 
        // For synthesized Codable, missing keys cause decode failure → loadConfig falls back to default Config().
        // If file exists with old keys only, decode succeeds and snapshotEverySeconds gets 0!
        // Prefer ≥30min sparse snaps (was 600s in older defaults).
        if c.snapshotEverySeconds < 1800 {
            c.snapshotEverySeconds = 1800
            changed = true
        }
        // Tighten historical keep=5+ → 3 (db-only snaps still cost cloud if CoW broken).
        if c.keepSnapshots > 3 {
            c.keepSnapshots = 3
            changed = true
        }
        let beforeDest = c.destinations
        c.destinations = BackupDestinationResolver.normalizeDestinations(c.destinations)
        if c.destinations != beforeDest { changed = true }
        c = Self.clamp(c)
        if changed {
            config = c
            saveConfig()
            print("[Backup] migrated config → keep=\(c.keepSnapshots) min=\(Int(c.minIntervalSeconds))s snapEvery=\(Int(c.snapshotEverySeconds))s dests=\(c.destinations.map{$0.id})")
        }
    }

    private static func clamp(_ c: Config) -> Config {
        var x = c
        x.keepSnapshots = max(1, min(x.keepSnapshots, 5))
        x.throttleSeconds = max(30, min(x.throttleSeconds, 600))
        x.minIntervalSeconds = max(30, min(x.minIntervalSeconds, 600))
        x.maxIntervalSeconds = max(x.minIntervalSeconds, min(x.maxIntervalSeconds, 3600))
        x.snapshotEverySeconds = max(x.minIntervalSeconds, min(x.snapshotEverySeconds, 86400))
        return x
    }

    // MARK: Paths

    static func cloudDocsURL() -> URL? { BackupDestinationResolver.cloudDocsURL() }
    static func googleDriveMyDriveURL() -> URL? { BackupDestinationResolver.googleDriveMyDriveURL() }

    /// Primary root for status display (first available enabled destination).
    var backupRootURL: URL? {
        for d in config.destinations where d.enabled {
            if let r = BackupDestinationResolver.backupRoot(for: d) { return r }
        }
        return BackupDestinationResolver.backupRoot(for: .icloudDefault)
            ?? BackupDestinationResolver.backupRoot(for: .gdriveDefault)
    }

    private var localWorkDir: URL {
        // Prefer KEEPSAKE/CLIPVAULT home (Application Support) — LaunchAgent has no
        // Documents TCC grant; sqlite journal fsync under ~/Documents can stall forever.
        let dir = DatabaseManager.resolveDataRoot()
            .appendingPathComponent(".backup_work", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func latestDir(in root: URL) -> URL { root.appendingPathComponent("latest", isDirectory: true) }
    private func snapshotsDir(in root: URL) -> URL { root.appendingPathComponent("snapshots", isDirectory: true) }
    private func blobsDir(in root: URL) -> URL { root.appendingPathComponent("blobs", isDirectory: true) }
    private func statusFile(in root: URL) -> URL { root.appendingPathComponent("STATUS.json") }

    /// Legacy single-root helpers (primary available dest).
    private var latestDir: URL? { backupRootURL.map { latestDir(in: $0) } }
    private var snapshotsDir: URL? { backupRootURL.map { snapshotsDir(in: $0) } }
    private var backupBlobsDir: URL? { backupRootURL.map { blobsDir(in: $0) } }
    private var statusFile: URL? { backupRootURL.map { statusFile(in: $0) } }

    private var enabledDestinations: [BackupDestinationConfig] {
        config.destinations.filter(\.enabled)
    }

    private static var localConfigURL: URL {
        let dir = DatabaseManager.resolveDataRoot().appendingPathComponent("config", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("backup.json")
    }

    private static func loadConfig() -> Config {
        let url = localConfigURL
        if let data = try? Data(contentsOf: url),
           let c = try? JSONDecoder().decode(Config.self, from: data) {
            return c
        }
        let def = Config.default
        try? JSONEncoder.pretty.encode(def).write(to: url, options: .atomic)
        return def
    }

    private func saveConfig() {
        try? JSONEncoder.pretty.encode(config).write(to: Self.localConfigURL, options: .atomic)
    }

    // MARK: Public

    func markDirty(reason: String) {
        queue.async { self.markDirtyLocked(reason: reason) }
    }

    private func markDirtyLocked(reason: String) {
        dirty = true
        lastPhase = "dirty:\(reason)"
        guard config.enabled else { return }
        scheduleThrottledBackup()
    }

    func updateConfig(_ body: [String: Any], completion: ((Config) -> Void)? = nil) {
        queue.async {
            if let v = body["enabled"] as? Bool { self.config.enabled = v }
            if let v = body["keepSnapshots"] as? Int { self.config.keepSnapshots = v }
            if let v = body["throttleSeconds"] as? Double { self.config.throttleSeconds = v }
            if let v = body["minIntervalSeconds"] as? Double { self.config.minIntervalSeconds = v }
            if let v = body["maxIntervalSeconds"] as? Double { self.config.maxIntervalSeconds = v }
            // NSNumber bridging
            if let v = body["keepSnapshots"] as? NSNumber { self.config.keepSnapshots = v.intValue }
            if let v = body["throttleSeconds"] as? NSNumber { self.config.throttleSeconds = v.doubleValue }
            if let v = body["minIntervalSeconds"] as? NSNumber { self.config.minIntervalSeconds = v.doubleValue }
            if let v = body["maxIntervalSeconds"] as? NSNumber { self.config.maxIntervalSeconds = v.doubleValue }

            if let v = body["snapshotEverySeconds"] as? Double { self.config.snapshotEverySeconds = v }
            if let v = body["snapshotEverySeconds"] as? NSNumber { self.config.snapshotEverySeconds = v.doubleValue }
            // Toggle destinations: { "destinationId": "gdrive", "destinationEnabled": true }
            if let destId = body["destinationId"] as? String {
                let en: Bool? = (body["destinationEnabled"] as? Bool)
                    ?? (body["destinationEnabled"] as? NSNumber).map { $0.boolValue }
                if let en = en, let idx = self.config.destinations.firstIndex(where: { $0.id == destId }) {
                    self.config.destinations[idx].enabled = en
                }
            }
            self.config.destinations = BackupDestinationResolver.normalizeDestinations(self.config.destinations)
            self.config = Self.clamp(self.config)
            self.saveConfig()
            self.pruneSnapshots(keep: self.config.keepSnapshots)
            if self.config.enabled { self.markDirtyLocked(reason: "config") }
            let c = self.config
            self.publishStatus()
            DispatchQueue.main.async { completion?(c) }
        }
    }

    func runNow(completion: ((Bool, String) -> Void)? = nil) {
        queue.async {
            self.dirty = true
            // Manual: always refresh latest + take a named snapshot
            self.performBackup(force: true, wantSnapshot: true) { ok, msg in
                DispatchQueue.main.async { completion?(ok, msg) }
            }
        }
    }

    func statusSnapshot(completion: @escaping (Status) -> Void) {
        queue.async {
            let st = self.buildStatus()
            DispatchQueue.main.async { completion(st) }
        }
    }

    func restore(snapshotId: String, completion: @escaping (Bool, String) -> Void) {
        queue.async {
            guard !self.inProgress else {
                DispatchQueue.main.async { completion(false, "备份进行中，请稍后恢复") }
                return
            }
            guard let root = self.backupRootURL else {
                DispatchQueue.main.async { completion(false, "iCloud Drive (CloudDocs) 不可用") }
                return
            }
            let srcDB: URL = snapshotId == "latest"
                ? root.appendingPathComponent("latest/clipflow.db")
                : root.appendingPathComponent("snapshots/\(snapshotId)/clipflow.db")
            guard self.fm.fileExists(atPath: srcDB.path) else {
                DispatchQueue.main.async { completion(false, "快照不存在: \(snapshotId)") }
                return
            }

            self.inProgress = true
            self.lastPhase = "restore:safety_snapshot"
            self.publishStatus()
            let safetyId = Self.timestampId() + "-pre-restore"

            self.performBackup(force: true, snapshotOverrideId: safetyId) { [weak self] _, _ in
                guard let self = self else { return }
                self.lastPhase = "restore:blobs"
                // Pull CAS blobs from backup before swapping db so images resolve.
                self.restoreBlobsFromBackupCAS()
                self.lastPhase = "restore:replace"
                self.publishStatus()
                self.database.replaceDatabaseFile(with: srcDB) { result in
                    self.queue.async {
                        self.inProgress = false
                        switch result {
                        case .success:
                            self.lastError = nil
                            self.lastPhase = "restore:ok"
                            self.lastSuccessUnix = Date().timeIntervalSince1970
                            self.dirty = false
                            self.writeStatusFile()
                            self.publishStatus()
                            NotificationCenter.default.post(name: Self.itemAddedNotification, object: nil)
                            DispatchQueue.main.async {
                                completion(true, "已从 \(snapshotId) 恢复（恢复前快照 \(safetyId)）")
                            }
                        case .failure(let err):
                            self.lastError = err.localizedDescription
                            self.lastPhase = "restore:fail"
                            self.publishStatus()
                            DispatchQueue.main.async {
                                completion(false, "恢复失败: \(err.localizedDescription)")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Scheduling

    private func scheduleThrottledBackup() {
        throttleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performBackup(force: false, completion: nil)
        }
        throttleWorkItem = work
        queue.asyncAfter(deadline: .now() + config.throttleSeconds, execute: work)
    }

    private func startMaxIntervalWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard self.config.enabled, self.dirty, !self.inProgress else { return }
            let now = Date().timeIntervalSince1970
            if let last = self.lastSuccessUnix {
                if now - last >= self.config.maxIntervalSeconds {
                    self.performBackup(force: true, completion: nil)
                }
            } else {
                self.performBackup(force: true, completion: nil)
            }
        }
        t.resume()
        maxIntervalTimer = t
    }

    // MARK: Core backup

    private func performBackup(
        force: Bool,
        snapshotOverrideId: String? = nil,
        wantSnapshot: Bool = false,
        completion: ((Bool, String) -> Void)?
    ) {
        if inProgress {
            completion?(false, "in_progress")
            return
        }
        if !config.enabled && snapshotOverrideId == nil {
            completion?(false, "disabled")
            return
        }
        if !force && !dirty {
            completion?(false, "clean")
            return
        }
        let now = Date().timeIntervalSince1970
        if !force, let last = lastSuccessUnix, now - last < config.minIntervalSeconds {
            scheduleThrottledBackup()
            completion?(false, "min_interval")
            return
        }

        // Resolve destinations up front
        let dests = enabledDestinations.compactMap { d -> (BackupDestinationConfig, URL)? in
            guard BackupDestinationResolver.isDestinationReady(d),
                  let root = BackupDestinationResolver.backupRoot(for: d) else { return nil }
            return (d, root)
        }
        if dests.isEmpty {
            lastError = "没有可用的备份目标。请启用 iCloud 云盘、登录 Google Drive，或安装夸克并在客户端开启目录同步。"
            lastPhase = "error:no_destination"
            publishStatus()
            completion?(false, lastError!)
            return
        }

        inProgress = true
        lastPhase = "prepare"
        lastError = nil
        publishStatus()

        // Produce artifact once in local work dir (sqlite skill: one backup API call).
        let work = localWorkDir
        let tmpURL = work.appendingPathComponent("artifact_\(UUID().uuidString).db")

        lastPhase = "sqlite3_backup"
        publishStatus()

        database.onlineBackup(to: tmpURL) { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                switch result {
                case .failure(let err):
                    try? self.fm.removeItem(at: tmpURL)
                    self.inProgress = false
                    self.lastError = err.localizedDescription
                    self.lastPhase = "error:backup"
                    self.publishStatus()
                    completion?(false, err.localizedDescription)

                case .success:
                    let compactURL = work.appendingPathComponent("compact_\(UUID().uuidString).db")
                    let artifact: URL
                    if self.compactBackupFile(from: tmpURL, to: compactURL) {
                        try? self.fm.removeItem(at: tmpURL)
                        artifact = compactURL
                    } else {
                        try? self.fm.removeItem(at: compactURL)
                        artifact = tmpURL
                    }

                    let sha = (try? Self.sha256File(artifact)) ?? ""
                    let size = (try? self.fm.attributesOfItem(atPath: artifact.path)[.size] as? NSNumber)?.intValue ?? 0
                    let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
                    let created = Date()
                    let iso = ClipTimeFormat.isoLocal(created)

                    self.database.itemCount { count in
                        self.queue.async {
                            var anyOk = false
                            var messages: [String] = []
                            var totalBlobNew = 0
                            var lastBlobCount = 0
                            var lastBlobBytes = 0
                            var snapIdGlobal: String? = nil

                            let shouldSnap =
                                snapshotOverrideId != nil
                                || wantSnapshot
                                || self.shouldCreateNamedSnapshot(now: created.timeIntervalSince1970)
                            let snapId = shouldSnap ? (snapshotOverrideId ?? Self.timestampId()) : nil

                            // Unchanged skip: only if ALL available dests already have this sha and no new blobs.
                            var allSkip = true

                            for (dest, root) in dests {
                                self.lastPhase = "push:\(dest.id)"
                                self.destLastPhase[dest.id] = "push"
                                do {
                                    let latest = self.latestDir(in: root)
                                    let snaps = self.snapshotsDir(in: root)
                                    let blobs = self.blobsDir(in: root)
                                    // Create parents step-by-step (Google Drive File Provider is picky).
                                    try self.ensureCloudDir(root.deletingLastPathComponent()) // ClipVault (or legacy Keepsake)/
                                    try self.ensureCloudDir(root) // backup/
                                    try self.ensureCloudDir(latest)
                                    try self.ensureCloudDir(snaps)
                                    try self.ensureCloudDir(blobs)
                                    self.scrubLatestTmpFiles(in: latest)

                                    // AGENTS.md §7 备份增量铁律：增量是核心；云目标禁止每轮 forceFull。
                                    // Quark staging = local APFS only → full re-copy allowed.
                                    // GDrive/iCloud File Providers: size-match skip; repair missing/partial only.
                                    // (Historical bug: forceFull on gdrive → EDEADLK / missing=N; never revive.)
                                    let forceFull = (dest.type == "quark")
                                    let cas = self.syncBlobsToCAS(
                                        destRoot: blobs,
                                        forceFullCopy: forceFull,
                                        cloudSafe: (dest.type == "gdrive" || dest.type == "icloud")
                                    )
                                    lastBlobCount = cas.total
                                    lastBlobBytes = cas.bytes
                                    totalBlobNew += cas.copied + cas.repaired

                                    // Refuse to publish this dest if CAS is incomplete on the mount.
                                    let verified = try self.verifyCASMirror(
                                        local: self.database.blobsDirectoryURL,
                                        dest: blobs
                                    )
                                    if !verified.ok {
                                        throw NSError(
                                            domain: "ClipFlow.Backup",
                                            code: 2,
                                            userInfo: [
                                                NSLocalizedDescriptionKey:
                                                    "blobs 校验失败 missing=\(verified.missing) sizeMismatch=\(verified.sizeMismatch)",
                                            ]
                                        )
                                    }

                                    let latestDB = latest.appendingPathComponent("clipflow.db")
                                    let latestManifest = latest.appendingPathComponent("MANIFEST.json")
                                    let prevMan = self.readManifest(latestManifest)

                                    if snapshotOverrideId == nil,
                                       prevMan?.sha256 == sha,
                                       prevMan?.blobsVerified == true,
                                       self.fm.fileExists(atPath: latestDB.path),
                                       cas.copied == 0,
                                       cas.repaired == 0 {
                                        self.destLastPhase[dest.id] = "skip:unchanged"
                                        self.destLastError[dest.id] = nil
                                        messages.append("\(BackupDestinationResolver.displayLabel(dest)): 未变")
                                        anyOk = true
                                        continue
                                    }
                                    allSkip = false

                                    // Promote db: full copy + fsync (never clone into File Provider).
                                    try self.publishFileFullCopy(from: artifact, to: latestDB)

                                    let blobNames = self.listBinNames(in: blobs)
                                    let manifest = Manifest(
                                        createdAt: iso,
                                        createdAtUnix: created.timeIntervalSince1970,
                                        sourcePath: self.database.dbFileURL.path,
                                        byteSize: size,
                                        sha256: sha,
                                        itemCount: count,
                                        host: host,
                                        note: "dest:\(dest.id)" + (snapId.map { " snap:\($0)" } ?? ""),
                                        blobCount: blobNames.count,
                                        blobBytes: cas.bytes,
                                        blobFiles: blobNames,
                                        blobsVerified: true
                                    )
                                    try self.writeJSONAtomic(manifest, to: latestManifest)
                                    // fsync db + manifest so File Provider sees durable close
                                    self.fullFsync(latestDB)
                                    self.fullFsync(latestManifest)

                                    if let snapId = snapId {
                                        // Named snapshots are best-effort on File Providers (EDEADLK on mkdir).
                                        // latest/ + blobs/ are the disaster-recovery surface; snap failure must not fail the dest.
                                        do {
                                            let snapDir = snaps.appendingPathComponent(snapId, isDirectory: true)
                                            try self.ensureCloudDir(snapDir)
                                            let snapDB = snapDir.appendingPathComponent("clipflow.db")
                                            try self.publishFileFullCopy(from: latestDB, to: snapDB, cloudSafe: (dest.type == "gdrive" || dest.type == "icloud"))
                                            try self.writeJSONAtomic(
                                                manifest,
                                                to: snapDir.appendingPathComponent("MANIFEST.json")
                                            )
                                            snapIdGlobal = snapId
                                        } catch {
                                            print("[Backup] snapshot skipped dest=\(dest.id) id=\(snapId): \(error)")
                                        }
                                    }

                                    self.pruneSnapshots(in: snaps, keep: self.config.keepSnapshots)
                                    self.destLastSuccessUnix[dest.id] = created.timeIntervalSince1970
                                    self.destLastError[dest.id] = nil
                                    // Quark: only local staging write is guaranteed. Cloud list is a soft signal.
                                    if dest.type == "quark" {
                                        let qd = BackupDestinationResolver.discoverQuark()
                                        self.destLastPhase[dest.id] = qd.cloudListedClipVaultBackups
                                            ? "ok:staging_cloud_listed"
                                            : "ok:local_staging"
                                    } else {
                                        self.destLastPhase[dest.id] = "ok"
                                    }
                                    anyOk = true
                                    let repairedNote = cas.repaired > 0 ? " repair=\(cas.repaired)" : ""
                                    messages.append(
                                        "\(BackupDestinationResolver.displayLabel(dest)): ok blobs=\(blobNames.count)\(repairedNote)"
                                    )
                                    print(
                                        "[Backup] dest=\(dest.id) ok db=\(Self.byteString(size)) "
                                            + "blobs=\(blobNames.count) +\(cas.copied)/repair\(cas.repaired) fullCopy=\(forceFull)"
                                    )
                                } catch {
                                    allSkip = false
                                    // GDrive File Provider often returns EDEADLK for the whole tree.
                                    // Fall back to local APFS staging (same honesty model as 夸克).
                                    if dest.type == "gdrive" {
                                        do {
                                            let stage = self.gdriveLocalStagingRoot()
                                            try self.publishFullBackupToLocalRoot(
                                                root: stage,
                                                artifact: artifact,
                                                sha: sha,
                                                size: size,
                                                count: count,
                                                host: host,
                                                iso: iso,
                                                created: created,
                                                snapId: snapId
                                            )
                                            self.destLastError[dest.id] = nil
                                            self.destLastPhase[dest.id] = "ok:local_staging"
                                            self.destLastSuccessUnix[dest.id] = created.timeIntervalSince1970
                                            messages.append("Google Drive: 本机暂存（云端 File Provider 死锁/不可写）")
                                            anyOk = true
                                            print("[Backup] dest=gdrive cloud fail → local staging ok: \(stage.path) (cloud err: \(error.localizedDescription))")
                                            continue
                                        } catch {
                                            print("[Backup] dest=gdrive staging also failed: \(error)")
                                        }
                                    }
                                    self.destLastError[dest.id] = error.localizedDescription
                                    self.destLastPhase[dest.id] = "error"
                                    messages.append("\(BackupDestinationResolver.displayLabel(dest)): 失败")
                                    print("[Backup] dest=\(dest.id) fail \(error)")
                                }
                            }

                            try? self.fm.removeItem(at: artifact)
                            self.scrubLegacyArtifacts()

                            if allSkip && anyOk {
                                self.dirty = false
                                self.inProgress = false
                                self.lastPhase = "skip:unchanged"
                                self.lastError = nil
                                self.publishStatus()
                                completion?(true, "内容未变，跳过 · " + messages.joined(separator: " · "))
                                return
                            }

                            if let snapIdGlobal = snapIdGlobal {
                                self.lastSnapshotUnix = created.timeIntervalSince1970
                            }
                            self.lastContentFingerprint = sha
                            if anyOk {
                                self.lastSuccessUnix = created.timeIntervalSince1970
                                self.dirty = false
                                self.lastPhase = "ok"
                                let fails = messages.filter { $0.contains("失败") }
                                self.lastError = fails.isEmpty ? nil : fails.joined(separator: "; ")
                            } else {
                                self.lastPhase = "error:all_dest"
                                self.lastError = messages.joined(separator: "; ")
                            }
                            self.inProgress = false
                            self.writeStatusFile()
                            self.publishStatus()
                            let snapNote = snapIdGlobal.map { "快照 \($0)" } ?? "仅 latest"
                            let msg = (anyOk ? "已备份" : "备份失败")
                                + " · \(snapNote) · db \(Self.byteString(size)) · blobs \(lastBlobCount) (+\(totalBlobNew)) · "
                                + messages.joined(separator: " · ")
                            print("[Backup] \(msg)")
                            completion?(anyOk, msg)
                        }
                    }
                }
            }
        }
    }

    /// `VACUUM INTO` when possible — smaller single-file artifact for iCloud.
    private func compactBackupFile(from src: URL, to dest: URL) -> Bool {
        var db: OpaquePointer?
        defer {
            if db != nil { sqlite3_close(db) }
        }
        guard sqlite3_open_v2(src.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db else {
            return false
        }
        try? fm.removeItem(at: dest)
        let destPath = dest.path.replacingOccurrences(of: "'", with: "''")
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, "VACUUM INTO '\(destPath)';", nil, nil, &err)
        if rc != SQLITE_OK {
            if let err { sqlite3_free(err) }
            try? fm.removeItem(at: dest)
            return false
        }
        return fm.fileExists(atPath: dest.path)
    }

    private struct CASSyncResult {
        var total: Int
        var bytes: Int
        var copied: Int
        var repaired: Int
    }

    private struct CASVerifyResult {
        var ok: Bool
        var missing: Int
        var sizeMismatch: Int
    }

    /// Mirror local CAS into destination `blobs/`.
    /// - forceFullCopy: rewrite every blob (local staging only; never on GDrive).
    /// - cloudSafe: stream write + long backoff; never bulk delete+copyItem (EDEADLK).
    private func syncBlobsToCAS(destRoot: URL, forceFullCopy: Bool, cloudSafe: Bool = false) -> CASSyncResult {
        try? fm.createDirectory(at: destRoot, withIntermediateDirectories: true)
        scrubCloudTmpFiles(in: destRoot)
        let local = database.blobsDirectoryURL
        guard let files = try? fm.contentsOfDirectory(
            at: local,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return CASSyncResult(total: 0, bytes: 0, copied: 0, repaired: 0)
        }
        var total = 0
        var bytes = 0
        var copied = 0
        var repaired = 0
        var failures = 0
        var consecutiveFailures = 0
        for src in files where src.pathExtension == "bin" {
            total += 1
            let size = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            bytes += size
            let dest = destRoot.appendingPathComponent(src.lastPathComponent)
            let existed = fm.fileExists(atPath: dest.path)
            if existed && !forceFullCopy {
                let destSize = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                // Empty / partial File Provider placeholders often report size 0.
                if destSize == size, size > 0 {
                    consecutiveFailures = 0
                    continue
                }
            }
            do {
                // Do NOT pre-delete dest: GDrive File Provider thrashing → EDEADLK on mass remove+copy.
                try publishFileFullCopy(
                    from: src,
                    to: dest,
                    allowClone: !forceFullCopy && !cloudSafe,
                    cloudSafe: cloudSafe
                )
                if existed { repaired += 1 } else { copied += 1 }
                consecutiveFailures = 0
            } catch {
                failures += 1
                consecutiveFailures += 1
                print("[Backup] blob copy failed \(src.lastPathComponent): \(error)")
                if cloudSafe {
                    // Cooling period after a streak of deadlocks.
                    let cool = min(2_000_000, 200_000 * UInt32(consecutiveFailures))
                    usleep(cool)
                }
            }
            // Give Google Drive File Provider time between files.
            if cloudSafe {
                usleep(80_000)
            }
        }
        if failures > 0 {
            print("[Backup] CAS mirror incomplete failures=\(failures)/\(total) cloudSafe=\(cloudSafe)")
        }
        return CASSyncResult(total: total, bytes: bytes, copied: copied, repaired: repaired)
    }

    /// Ensure every local CAS file exists on dest with identical size.
    private func verifyCASMirror(local: URL, dest: URL) throws -> CASVerifyResult {
        let localFiles = (try? fm.contentsOfDirectory(
            at: local,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var missing = 0
        var sizeMismatch = 0
        for src in localFiles where src.pathExtension == "bin" {
            let name = src.lastPathComponent
            let d = dest.appendingPathComponent(name)
            guard fm.fileExists(atPath: d.path) else {
                missing += 1
                continue
            }
            let srcSize = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            let destSize = (try? d.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
            if srcSize != destSize || srcSize <= 0 {
                sizeMismatch += 1
            }
        }
        return CASVerifyResult(
            ok: missing == 0 && sizeMismatch == 0,
            missing: missing,
            sizeMismatch: sizeMismatch
        )
    }

    private func listBinNames(in dir: URL) -> [String] {
        let files = (try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .map(\.lastPathComponent)
            .filter { $0.hasSuffix(".bin") }
            .sorted()
    }

    /// Full byte copy into cloud mounts. Prefer copyItem; optional clone only for local disks.
    /// - cloudSafe: stream write + /bin/cp fallback; no F_FULLFSYNC; long EDEADLK backoff.
    private func publishFileFullCopy(
        from src: URL,
        to dst: URL,
        allowClone: Bool = false,
        cloudSafe: Bool = false
    ) throws {
        let cloud = cloudSafe || isCloudFileProviderURL(dst)
        if !cloud {
            // Local APFS path: clone optional, fullFsync for durability.
            if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
            if allowClone {
                let rc = clonefile(src.path, dst.path, 0)
                if rc == 0 { return }
            }
            let tmp = dst.deletingLastPathComponent()
                .appendingPathComponent(".tmp_\(UUID().uuidString)_\(dst.lastPathComponent)")
            try fm.copyItem(at: src, to: tmp)
            fullFsync(tmp)
            if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
            try fm.moveItem(at: tmp, to: dst)
            fullFsync(dst)
            return
        }

        // --- Cloud File Provider (GDrive / iCloud) ---
        // Never F_FULLFSYNC. Prefer stream write; FileManager.copyItem often hits EDEADLK.
        let expected = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        if expected > 0, fm.fileExists(atPath: dst.path) {
            let got = (try? dst.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            if got == expected { return }
        }

        var lastError: Error?
        for attempt in 0..<8 {
            let tmp = dst.deletingLastPathComponent()
                .appendingPathComponent(".tmp_\(UUID().uuidString)_\(dst.lastPathComponent)")
            do {
                if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
                // Strategy A: stream bytes (avoids copyfile/clonefile path that deadlocks).
                try streamCopyNoFsync(from: src, to: tmp)
                try promoteCloudTmp(tmp: tmp, dst: dst, expected: expected)
                return
            } catch {
                lastError = error
                try? fm.removeItem(at: tmp)
            }
            // Strategy B: /bin/cp subprocess (sometimes succeeds when Foundation fails).
            do {
                if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
                try shellCp(from: src, to: tmp)
                try promoteCloudTmp(tmp: tmp, dst: dst, expected: expected)
                return
            } catch {
                lastError = error
                try? fm.removeItem(at: tmp)
                if isTransientCloudCopyError(error) || isTransientCloudCopyError(lastError!) {
                    // Exponential-ish backoff: 0.15s → ~3.5s
                    let usec = UInt32(min(3_500_000, 150_000 * (1 << min(attempt, 4))))
                    usleep(usec)
                    continue
                }
                throw error
            }
        }
        if let lastError { throw lastError }
    }

    /// Byte-stream copy without fsync/fullfsync (File Provider safe).
    private func streamCopyNoFsync(from src: URL, to dst: URL) throws {
        let inFd = open(src.path, O_RDONLY)
        guard inFd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "open src failed \(src.lastPathComponent)"
            ])
        }
        defer { close(inFd) }
        let outFd = open(dst.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard outFd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "open dst failed \(dst.lastPathComponent)"
            ])
        }
        defer { close(outFd) }
        var buf = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let n = read(inFd, &buf, buf.count)
            if n == 0 { break }
            if n < 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                    NSLocalizedDescriptionKey: "read failed"
                ])
            }
            var off = 0
            while off < n {
                let w = write(outFd, &buf[off], n - off)
                if w <= 0 {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                        NSLocalizedDescriptionKey: "write failed"
                    ])
                }
                off += w
            }
        }
        // flush kernel buffers only — no F_FULLFSYNC
        _ = fsync(outFd)
    }

    private func shellCp(from src: URL, to dst: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/cp")
        p.arguments = ["-f", src.path, dst.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "cp failed"
            throw NSError(domain: "ClipFlow.Backup", code: 11, userInfo: [
                NSLocalizedDescriptionKey: msg,
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EDEADLK), userInfo: nil)
            ])
        }
    }

    private func promoteCloudTmp(tmp: URL, dst: URL, expected: Int) throws {
        let tmpSize = (try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        if expected > 0, tmpSize != expected {
            try? fm.removeItem(at: tmp)
            throw NSError(domain: "ClipFlow.Backup", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "tmp size \(tmpSize) != expected \(expected)"
            ])
        }
        // Replace final name: prefer replaceItemAt; fall back to remove+move.
        if fm.fileExists(atPath: dst.path) {
            do {
                _ = try fm.replaceItemAt(dst, withItemAt: tmp)
            } catch {
                try? fm.removeItem(at: dst)
                try fm.moveItem(at: tmp, to: dst)
            }
        } else {
            try fm.moveItem(at: tmp, to: dst)
        }
        let got = (try? dst.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        if expected > 0, got != expected {
            throw NSError(domain: "ClipFlow.Backup", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "dest size \(got) != expected \(expected)"
            ])
        }
    }

    private func scrubCloudTmpFiles(in dir: URL) {
        let all = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])) ?? []
        for f in all {
            let name = f.lastPathComponent
            if name.hasPrefix(".tmp_") || name.hasPrefix(".probe") {
                try? fm.removeItem(at: f)
            }
        }
    }

    private func writeJSONAtomic<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder.pretty.encode(value)
        let cloud = isCloudFileProviderURL(url)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".tmp_\(UUID().uuidString)_\(url.lastPathComponent)")
        try data.write(to: tmp, options: .atomic)
        if !cloud { fullFsync(tmp) }
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.moveItem(at: tmp, to: url)
        if !cloud { fullFsync(url) }
    }

    /// F_FULLFSYNC on Google Drive / iCloud File Provider paths frequently returns
    /// EDEADLK ("Resource deadlock avoided") and aborts whole CAS mirrors.
    private func isCloudFileProviderURL(_ url: URL) -> Bool {
        let p = url.path
        return p.contains("/Library/CloudStorage/")
            || p.contains("/Mobile Documents/")
            || p.contains("GoogleDrive-")
    }

    private func isTransientCloudCopyError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EDEADLK) || ns.code == Int(EAGAIN) {
            return true
        }
        if let und = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           und.domain == NSPOSIXErrorDomain,
           und.code == Int(EDEADLK) || und.code == Int(EAGAIN) {
            return true
        }
        // NSCocoaErrorDomain 512 "couldn't be copied" often wraps EDEADLK for File Providers.
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteUnknownError || ns.code == 512 {
            if let und = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
               und.domain == NSPOSIXErrorDomain {
                return und.code == Int(EDEADLK) || und.code == Int(EAGAIN) || und.code == Int(EBUSY)
            }
        }
        return false
    }

    /// Request durable write on **local** APFS only. No-op for cloud File Providers.
    private func fullFsync(_ url: URL) {
        if isCloudFileProviderURL(url) { return }
        let path = url.path
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }
        if fcntl(fd, F_FULLFSYNC) == -1 {
            _ = fsync(fd)
        }
        close(fd)
    }

    private func scrubLatestTmpFiles(in latest: URL) {
        let files = (try? fm.contentsOfDirectory(at: latest, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for f in files {
            let name = f.lastPathComponent
            if name.hasPrefix(".tmp_") || name.hasSuffix("-shm") || name.hasSuffix("-wal") {
                // Keep only final clipflow.db; drop interrupted temps.
                if name != "clipflow.db" && name != "MANIFEST.json" {
                    try? fm.removeItem(at: f)
                }
            }
        }
        // Also remove hidden tmp with skipsHiddenFiles off
        let all = (try? fm.contentsOfDirectory(at: latest, includingPropertiesForKeys: nil, options: [])) ?? []
        for f in all where f.lastPathComponent.hasPrefix(".tmp_") {
            try? fm.removeItem(at: f)
        }
    }

    /// Drop legacy DuckDB + oversized junk under CloudDocs ClipFlow.
    private func scrubLegacyArtifacts() {
        guard let cloud = Self.cloudDocsURL() else { return }
        let duck = cloud.appendingPathComponent("ClipFlow/db/clipflow.duckdb")
        if fm.fileExists(atPath: duck.path) {
            try? fm.removeItem(at: duck)
            print("[Backup] removed legacy DuckDB \(duck.path)")
        }
        let duckDir = cloud.appendingPathComponent("ClipFlow/db")
        if let rest = try? fm.contentsOfDirectory(at: duckDir, includingPropertiesForKeys: nil), rest.isEmpty {
            try? fm.removeItem(at: duckDir)
        }
        // Drop old full-db snapshot trees beyond keep (also remove nested blobs if any).
        pruneSnapshots(keep: config.keepSnapshots)
    }

    private func restoreBlobsFromBackupCAS() {
        // Merge CAS from all available destinations (union of hashes).
        let local = database.blobsDirectoryURL
        try? fm.createDirectory(at: local, withIntermediateDirectories: true)
        for d in config.destinations {
            guard let root = BackupDestinationResolver.backupRoot(for: d) else { continue }
            let cas = blobsDir(in: root)
            guard fm.fileExists(atPath: cas.path) else { continue }
            let files = (try? fm.contentsOfDirectory(at: cas, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for src in files where src.pathExtension == "bin" {
                let hash = src.deletingPathExtension().lastPathComponent
                database.importBlobIfNeeded(hash: hash, from: src)
            }
        }
    }

    private func shouldCreateNamedSnapshot(now: Double) -> Bool {
        guard let last = lastSnapshotUnix ?? newestSnapshotUnix() else {
            return true // none yet
        }
        return now - last >= config.snapshotEverySeconds
    }

    private func newestSnapshotUnix() -> Double? {
        guard let snaps = snapshotsDir else { return nil }
        let dirs = ((try? fm.contentsOfDirectory(at: snaps, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
        var best: Double = 0
        for dir in dirs {
            let man = readManifest(dir.appendingPathComponent("MANIFEST.json"))
            if let u = man?.createdAtUnix, u > best { best = u }
            else if let d = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                best = max(best, d.timeIntervalSince1970)
            }
        }
        return best > 0 ? best : nil
    }

    /// APFS clonefile when possible (block-level CoW ≈ incremental on same volume).
    private func cloneOrCopy(from src: URL, to dst: URL) throws {
        // Local-only convenience. Cloud dests must use publishFileFullCopy.
        try publishFileFullCopy(from: src, to: dst, allowClone: true)
    }

    /// File Provider (Google Drive) often fails multi-level createDirectory in one call.

    /// Local APFS staging for Google Drive when File Provider is wedged (EDEADLK).
    /// User can still upload `~/ClipVault-Backups/GDrive/backup` via Drive web or mirror mode.
    private func gdriveLocalStagingRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ClipVault-Backups/GDrive/backup", isDirectory: true)
    }

    /// Write a complete backup package to a **local** root (APFS). Always full-copy CAS.
    private func publishFullBackupToLocalRoot(
        root: URL,
        artifact: URL,
        sha: String,
        size: Int,
        count: Int,
        host: String,
        iso: String,
        created: Date,
        snapId: String?
    ) throws {
        let latest = latestDir(in: root)
        let snaps = snapshotsDir(in: root)
        let blobs = blobsDir(in: root)
        try fm.createDirectory(at: latest, withIntermediateDirectories: true)
        try fm.createDirectory(at: snaps, withIntermediateDirectories: true)
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        let cas = syncBlobsToCAS(destRoot: blobs, forceFullCopy: true, cloudSafe: false)
        let verified = try verifyCASMirror(local: database.blobsDirectoryURL, dest: blobs)
        guard verified.ok else {
            throw NSError(domain: "ClipFlow.Backup", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "staging blobs missing=\(verified.missing) sizeMismatch=\(verified.sizeMismatch)"
            ])
        }
        let latestDB = latest.appendingPathComponent("clipflow.db")
        let latestManifest = latest.appendingPathComponent("MANIFEST.json")
        try publishFileFullCopy(from: artifact, to: latestDB, allowClone: true, cloudSafe: false)
        let blobNames = listBinNames(in: blobs)
        let manifest = Manifest(
            createdAt: iso,
            createdAtUnix: created.timeIntervalSince1970,
            sourcePath: database.dbFileURL.path,
            byteSize: size,
            sha256: sha,
            itemCount: count,
            host: host,
            note: "dest:gdrive-staging" + (snapId.map { " snap:\($0)" } ?? ""),
            blobCount: blobNames.count,
            blobBytes: cas.bytes,
            blobFiles: blobNames,
            blobsVerified: true
        )
        try writeJSONAtomic(manifest, to: latestManifest)
        if let snapId = snapId {
            let snapDir = snaps.appendingPathComponent(snapId, isDirectory: true)
            try fm.createDirectory(at: snapDir, withIntermediateDirectories: true)
            try publishFileFullCopy(from: latestDB, to: snapDir.appendingPathComponent("clipflow.db"), allowClone: true)
            try writeJSONAtomic(manifest, to: snapDir.appendingPathComponent("MANIFEST.json"))
        }
        pruneSnapshots(in: snaps, keep: config.keepSnapshots)
        _ = cas
    }

    private func ensureCloudDir(_ url: URL) throws {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue { return }
            try fm.removeItem(at: url)
        }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            // Retry once after short yield
            Thread.sleep(forTimeInterval: 0.15)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func pruneSnapshots(keep: Int) {
        for d in enabledDestinations {
            if let root = BackupDestinationResolver.backupRoot(for: d) {
                pruneSnapshots(in: snapshotsDir(in: root), keep: keep)
            }
        }
    }

    private func pruneSnapshots(in snaps: URL, keep: Int) {
        let dirs = ((try? fm.contentsOfDirectory(
            at: snaps,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter { url in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }

        // Drop legacy fat snapshots (pre blob-externalization full-db copies > 5MB).
        for dir in dirs {
            let db = dir.appendingPathComponent("clipflow.db")
            let sz = fileSize(db) ?? 0
            if sz > 5 * 1024 * 1024 {
                try? fm.removeItem(at: dir)
                print("[Backup] pruned fat legacy snapshot \(dir.lastPathComponent) (\(sz) bytes)")
            }
        }

        let dirs2 = ((try? fm.contentsOfDirectory(
            at: snaps,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter { url in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }

        if dirs2.count > keep {
            for url in dirs2.suffix(from: keep) {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: Status

    private func buildStatus() -> Status {
        let cloud = Self.cloudDocsURL()
        let gdrive = Self.googleDriveMyDriveURL()
        let root = backupRootURL
        var latestInfo: SnapshotInfo?
        if let latestDB = latestDir?.appendingPathComponent("clipflow.db"),
           fm.fileExists(atPath: latestDB.path) {
            let man = latestDir.flatMap { readManifest($0.appendingPathComponent("MANIFEST.json")) }
            latestInfo = SnapshotInfo(
                id: "latest",
                path: latestDB.path,
                createdAt: man?.createdAt,
                byteSize: man?.byteSize ?? fileSize(latestDB),
                sha256: man?.sha256,
                itemCount: man?.itemCount,
                isLatest: true
            )
        }
        var snaps: [SnapshotInfo] = []
        if let snapsDir = snapshotsDir {
            let dirs = ((try? fm.contentsOfDirectory(at: snapsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for dir in dirs {
                let db = dir.appendingPathComponent("clipflow.db")
                guard fm.fileExists(atPath: db.path) else { continue }
                let man = readManifest(dir.appendingPathComponent("MANIFEST.json"))
                snaps.append(SnapshotInfo(
                    id: dir.lastPathComponent,
                    path: db.path,
                    createdAt: man?.createdAt,
                    byteSize: man?.byteSize ?? fileSize(db),
                    sha256: man?.sha256,
                    itemCount: man?.itemCount,
                    isLatest: false
                ))
            }
        }
        let lastISO = lastSuccessUnix.map { ClipTimeFormat.isoLocal(unix: $0) }
        let lastSnapISO = (lastSnapshotUnix ?? newestSnapshotUnix()).map {
            ClipTimeFormat.isoLocal(unix: $0)
        }
        let destStatuses: [BackupDestinationStatus] = config.destinations.map { d in
            var rootURL = BackupDestinationResolver.backupRoot(for: d)
            // Path alone is not enough for quark (staging is always creatable).
            let avail = BackupDestinationResolver.isDestinationReady(d)
            let lastU = destLastSuccessUnix[d.id]
            var phase = destLastPhase[d.id]
            // Quark honesty: local write ≠ full cloud CAS verify.
            if d.type == "quark" {
                let qd = BackupDestinationResolver.discoverQuark()
                if phase == "ok" || phase == nil {
                    phase = qd.cloudListedClipVaultBackups ? "ok:staging_cloud_listed" : "ok:local_staging"
                } else if phase == "ok:local_staging", qd.cloudListedClipVaultBackups {
                    phase = "ok:staging_cloud_listed"
                }
            }
            var hint = BackupDestinationResolver.availabilityHint(for: d)
            // GDrive: when File Provider is wedged we stage locally — surface path + honesty.
            if d.type == "gdrive", phase == "ok:local_staging" {
                let stage = gdriveLocalStagingRoot()
                rootURL = stage
                hint = "ClipVault→本机暂存（Google Drive File Provider 不可写/EDEADLK） · 路径: \(stage.path) · 请重启 Google Drive 后点备份，或手动上传该文件夹到网盘"
            }
            let showHint = (d.type == "quark") || (d.type == "gdrive" && phase == "ok:local_staging") || !avail
            return BackupDestinationStatus(
                id: d.id,
                type: d.type,
                label: BackupDestinationResolver.displayLabel(d),
                enabled: d.enabled,
                available: avail,
                rootPath: rootURL?.path,
                lastSuccessAt: lastU.map { ClipTimeFormat.isoLocal(unix: $0) },
                lastSuccessUnix: lastU,
                lastError: destLastError[d.id],
                lastPhase: phase,
                hint: showHint ? hint : nil
            )
        }
        let onLabels = destStatuses.filter { $0.enabled && $0.available }.map(\.label)
        let policy = "多源 fan-out [\(onLabels.joined(separator: ", "))] · db+CAS · latest ≥\(Int(config.minIntervalSeconds))s · 快照 ≥\(Int(config.snapshotEverySeconds))s ×\(config.keepSnapshots)"
        return Status(
            enabled: config.enabled,
            cloudDocsAvailable: cloud != nil,
            cloudDocsPath: cloud?.path,
            backupRootPath: root?.path,
            lastSuccessAt: lastISO,
            lastSuccessUnix: lastSuccessUnix,
            lastError: lastError,
            lastPhase: lastPhase,
            inProgress: inProgress,
            dirty: dirty,
            latest: latestInfo,
            snapshots: snaps,
            config: config,
            policy: policy,
            lastSnapshotAt: lastSnapISO,
            lastSnapshotUnix: lastSnapshotUnix ?? newestSnapshotUnix(),
            snapshotCount: snaps.count,
            destinations: destStatuses,
            quarkDiscovery: BackupDestinationResolver.discoverQuark(),
            googleDriveAvailable: gdrive != nil,
            googleDrivePath: gdrive?.path
        )
    }

    private func publishStatus() {
        writeStatusFile()
        NotificationCenter.default.post(name: Self.statusChangedNotification, object: nil)
    }

    private func writeStatusFile() {
        let data = try? JSONEncoder.pretty.encode(buildStatus())
        // Write STATUS.json to every available destination root + local work dir.
        var roots: [URL] = [localWorkDir]
        for d in config.destinations {
            if let r = BackupDestinationResolver.backupRoot(for: d) { roots.append(r) }
        }
        for root in roots {
            let url = statusFile(in: root)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            if let data = data {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func readManifest(_ url: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    private func fileSize(_ url: URL) -> Int? {
        (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    private static func timestampId() -> String {
        ClipTimeFormat.localTimestampId()
    }

    private static func sha256File(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func byteString(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        return String(format: "%.2f MB", Double(n) / 1024 / 1024)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
