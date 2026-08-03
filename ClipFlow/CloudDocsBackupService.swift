import Foundation
import CryptoKit
import Darwin

/// Personal-machine SOTA backup to **iCloud Drive (CloudDocs)** — no App iCloud entitlements.
///
/// ## Strategy (minute-level, sparse versions)
/// - **latest/** — rolling head; updated about every minute when dirty (sqlite3_backup).
/// - **snapshots/** — sparse history; only every `snapshotEverySeconds`, max `keepSnapshots`.
/// - Unchanged content (SHA256) → skip write (true no-op for iCloud upload).
/// - Snapshot copy prefers APFS `clonefile` (CoW / near-incremental on disk).
///
/// ```
/// …/CloudDocs/ClipFlow/backup/
///   latest/{clipflow.db, MANIFEST.json}     # always newest
///   snapshots/YYYYMMDD-HHmmss/…            # few, timed
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

    /// Minute-level cadence + tight version budget.
    struct Config: Codable, Equatable {
        var enabled: Bool = true
        /// Named history dirs under snapshots/ (not counting latest/)
        var keepSnapshots: Int = 5
        /// Coalesce bursty clip writes before starting a backup
        var throttleSeconds: Double = 60
        /// Min gap between successive **latest** updates
        var minIntervalSeconds: Double = 60
        /// If still dirty, force latest update at least this often
        var maxIntervalSeconds: Double = 300
        /// Min gap between **named snapshots** (sparse history)
        var snapshotEverySeconds: Double = 600
        static let `default` = Config()
    }

    struct Manifest: Codable {
        var version: Int = 1
        var createdAt: String
        var createdAtUnix: Double
        var sourcePath: String
        var byteSize: Int
        var sha256: String
        var itemCount: Int?
        var engine: String = "sqlite3_backup"
        var host: String
        var note: String?
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
        var scheme: String = "CloudDocs"
        var requiresAppEntitlement: Bool = false
        /// Human policy summary for UI
        var policy: String = ""
        var lastSnapshotAt: String? = nil
        var snapshotCount: Int = 0
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

    private init(database: DatabaseManager) {
        self.database = database
        self.config = Self.loadConfig()
        self.migrateConfigIfNeeded()
        self.lastSnapshotUnix = self.newestSnapshotUnix()
        NotificationCenter.default.addObserver(
            forName: Self.itemAddedNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.markDirty(reason: "item_added")
        }
        startMaxIntervalWatchdog()
        // Prune excess versions from older chatty defaults
        queue.async { [weak self] in
            self?.pruneSnapshots(keep: self?.config.keepSnapshots ?? 5)
            self?.publishStatus()
        }
        if config.enabled {
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.markDirty(reason: "startup")
            }
        }
        print("[Backup] CloudDocs ready · enabled=\(config.enabled) · keep=\(config.keepSnapshots) · latest≥\(Int(config.minIntervalSeconds))s · snap≥\(Int(config.snapshotEverySeconds))s · root=\(backupRootURL?.path ?? "nil")")
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
        if c.snapshotEverySeconds < 120 {
            c.snapshotEverySeconds = 600
            changed = true
        }
        c = Self.clamp(c)
        if changed {
            config = c
            saveConfig()
            print("[Backup] migrated config → keep=\(c.keepSnapshots) min=\(Int(c.minIntervalSeconds))s snapEvery=\(Int(c.snapshotEverySeconds))s")
        }
    }

    private static func clamp(_ c: Config) -> Config {
        var x = c
        x.keepSnapshots = max(2, min(x.keepSnapshots, 10))
        x.throttleSeconds = max(30, min(x.throttleSeconds, 600))
        x.minIntervalSeconds = max(30, min(x.minIntervalSeconds, 600))
        x.maxIntervalSeconds = max(x.minIntervalSeconds, min(x.maxIntervalSeconds, 3600))
        x.snapshotEverySeconds = max(x.minIntervalSeconds, min(x.snapshotEverySeconds, 86400))
        return x
    }

    // MARK: Paths

    static func cloudDocsURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url.standardizedFileURL
        }
        return nil
    }

    var backupRootURL: URL? {
        Self.cloudDocsURL()?.appendingPathComponent("ClipFlow/backup", isDirectory: true)
    }

    private var latestDir: URL? { backupRootURL?.appendingPathComponent("latest", isDirectory: true) }
    private var snapshotsDir: URL? { backupRootURL?.appendingPathComponent("snapshots", isDirectory: true) }
    private var statusFile: URL? { backupRootURL?.appendingPathComponent("STATUS.json") }

    private static var localConfigURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = docs.appendingPathComponent("ClipFlow/config", isDirectory: true)
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

        guard let root = backupRootURL, let latest = latestDir, let snaps = snapshotsDir else {
            lastError = "iCloud Drive (CloudDocs) 不可用。请登录 iCloud 并启用「iCloud 云盘」。"
            lastPhase = "error:no_clouddocs"
            publishStatus()
            completion?(false, lastError!)
            return
        }
        _ = root

        inProgress = true
        lastPhase = "prepare"
        lastError = nil
        publishStatus()

        do {
            try fm.createDirectory(at: latest, withIntermediateDirectories: true)
            try fm.createDirectory(at: snaps, withIntermediateDirectories: true)
        } catch {
            inProgress = false
            lastError = "无法创建备份目录: \(error.localizedDescription)"
            lastPhase = "error:mkdir"
            publishStatus()
            completion?(false, lastError!)
            return
        }

        let tmpURL = latest.appendingPathComponent(".tmp_\(UUID().uuidString).db")
        let latestDB = latest.appendingPathComponent("clipflow.db")
        let latestManifest = latest.appendingPathComponent("MANIFEST.json")

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
                    let sha = (try? Self.sha256File(tmpURL)) ?? ""
                    let size = (try? self.fm.attributesOfItem(atPath: tmpURL.path)[.size] as? NSNumber)?.intValue ?? 0

                    if snapshotOverrideId == nil,
                       let prev = self.lastContentFingerprint,
                       prev == sha,
                       self.fm.fileExists(atPath: latestDB.path) {
                        try? self.fm.removeItem(at: tmpURL)
                        self.dirty = false
                        self.inProgress = false
                        self.lastPhase = "skip:unchanged"
                        self.publishStatus()
                        completion?(true, "内容未变，跳过")
                        return
                    }

                    self.lastPhase = "promote_latest"
                    do {
                        if self.fm.fileExists(atPath: latestDB.path) {
                            try self.fm.removeItem(at: latestDB)
                        }
                        try self.fm.moveItem(at: tmpURL, to: latestDB)
                    } catch {
                        try? self.fm.removeItem(at: tmpURL)
                        self.inProgress = false
                        self.lastError = error.localizedDescription
                        self.lastPhase = "error:promote"
                        self.publishStatus()
                        completion?(false, error.localizedDescription)
                        return
                    }

                    let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
                    let created = Date()
                    let iso = ISO8601DateFormatter().string(from: created)

                    self.database.itemCount { count in
                        self.queue.async {
                            let manifest = Manifest(
                                createdAt: iso,
                                createdAtUnix: created.timeIntervalSince1970,
                                sourcePath: self.database.dbFileURL.path,
                                byteSize: size,
                                sha256: sha,
                                itemCount: count,
                                host: host,
                                note: snapshotOverrideId.map { "id:\($0)" }
                            )
                            try? JSONEncoder.pretty.encode(manifest).write(to: latestManifest, options: .atomic)

                            // Sparse named snapshots (not every latest update)
                            var snapId: String? = nil
                            let shouldSnap =
                                snapshotOverrideId != nil
                                || wantSnapshot
                                || self.shouldCreateNamedSnapshot(now: created.timeIntervalSince1970)
                            if shouldSnap {
                                snapId = snapshotOverrideId ?? Self.timestampId()
                                let snapDir = snaps.appendingPathComponent(snapId!, isDirectory: true)
                                self.lastPhase = "snapshot:\(snapId!)"
                                do {
                                    try self.fm.createDirectory(at: snapDir, withIntermediateDirectories: true)
                                    let snapDB = snapDir.appendingPathComponent("clipflow.db")
                                    if self.fm.fileExists(atPath: snapDB.path) {
                                        try self.fm.removeItem(at: snapDB)
                                    }
                                    // Prefer APFS clonefile (CoW) — cheap "incremental" on disk
                                    try self.cloneOrCopy(from: latestDB, to: snapDB)
                                    try JSONEncoder.pretty.encode(manifest).write(
                                        to: snapDir.appendingPathComponent("MANIFEST.json"),
                                        options: .atomic
                                    )
                                    self.lastSnapshotUnix = created.timeIntervalSince1970
                                } catch {
                                    self.lastError = "latest 成功，快照失败: \(error.localizedDescription)"
                                    snapId = nil
                                }
                            }

                            self.pruneSnapshots(keep: self.config.keepSnapshots)
                            self.lastContentFingerprint = sha
                            self.lastSuccessUnix = created.timeIntervalSince1970
                            self.dirty = false
                            self.inProgress = false
                            self.lastPhase = "ok"
                            if self.lastError?.hasPrefix("latest 成功") != true {
                                self.lastError = nil
                            }
                            self.writeStatusFile()
                            self.publishStatus()
                            let snapNote = snapId.map { "快照 \($0)" } ?? "仅 latest"
                            let msg = "已备份 · \(snapNote) · \(Self.byteString(size))"
                            print("[Backup] \(msg)")
                            completion?(true, msg)
                        }
                    }
                }
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
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        let rc = clonefile(src.path, dst.path, 0)
        if rc == 0 { return }
        // Fallback full copy (iCloud will still delta-sync when possible)
        try fm.copyItem(at: src, to: dst)
    }

    private func pruneSnapshots(keep: Int) {

        guard let snaps = snapshotsDir else { return }
        let dirs = ((try? fm.contentsOfDirectory(
            at: snaps,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter { url in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }

        if dirs.count > keep {
            for url in dirs.suffix(from: keep) {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: Status

    private func buildStatus() -> Status {
        let cloud = Self.cloudDocsURL()
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
        let lastISO = lastSuccessUnix.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) }
        let lastSnapISO = (lastSnapshotUnix ?? newestSnapshotUnix()).map {
            ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0))
        }
        let policy = "latest 约每 \(Int(config.minIntervalSeconds))s；命名快照 ≥\(Int(config.snapshotEverySeconds))s；最多保留 \(config.keepSnapshots) 个"
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
            snapshotCount: snaps.count
        )
    }

    private func publishStatus() {
        writeStatusFile()
        NotificationCenter.default.post(name: Self.statusChangedNotification, object: nil)
    }

    private func writeStatusFile() {
        guard let statusFile = statusFile else { return }
        try? fm.createDirectory(at: statusFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder.pretty.encode(buildStatus()).write(to: statusFile, options: .atomic)
    }

    private func readManifest(_ url: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    private func fileSize(_ url: URL) -> Int? {
        (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    private static func timestampId() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmmss"
        return df.string(from: Date())
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
