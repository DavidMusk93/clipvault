import Foundation
import CryptoKit

/// Personal-machine SOTA backup to **iCloud Drive (CloudDocs)** — no App iCloud entitlements.
///
/// ```
/// ~/Library/Mobile Documents/com~apple~CloudDocs/ClipFlow/backup/
///   latest/{clipflow.db, MANIFEST.json}
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

    struct Config: Codable, Equatable {
        var enabled: Bool = true
        var keepSnapshots: Int = 20
        var throttleSeconds: Double = 3
        var minIntervalSeconds: Double = 30
        var maxIntervalSeconds: Double = 900
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

    private init(database: DatabaseManager) {
        self.database = database
        self.config = Self.loadConfig()
        NotificationCenter.default.addObserver(
            forName: Self.itemAddedNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.markDirty(reason: "item_added")
        }
        startMaxIntervalWatchdog()
        if config.enabled {
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.markDirty(reason: "startup")
            }
        }
        print("[Backup] CloudDocs service ready · enabled=\(config.enabled) · root=\(backupRootURL?.path ?? "nil")")
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

            self.config.keepSnapshots = max(3, min(self.config.keepSnapshots, 100))
            self.config.throttleSeconds = max(1, self.config.throttleSeconds)
            self.config.minIntervalSeconds = max(5, self.config.minIntervalSeconds)
            self.config.maxIntervalSeconds = max(self.config.minIntervalSeconds, self.config.maxIntervalSeconds)
            self.saveConfig()
            if self.config.enabled { self.markDirtyLocked(reason: "config") }
            let c = self.config
            self.publishStatus()
            DispatchQueue.main.async { completion?(c) }
        }
    }

    func runNow(completion: ((Bool, String) -> Void)? = nil) {
        queue.async {
            self.dirty = true
            self.performBackup(force: true) { ok, msg in
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

                            let snapId = snapshotOverrideId ?? Self.timestampId()
                            let snapDir = snaps.appendingPathComponent(snapId, isDirectory: true)
                            self.lastPhase = "snapshot:\(snapId)"
                            do {
                                try self.fm.createDirectory(at: snapDir, withIntermediateDirectories: true)
                                let snapDB = snapDir.appendingPathComponent("clipflow.db")
                                if self.fm.fileExists(atPath: snapDB.path) {
                                    try self.fm.removeItem(at: snapDB)
                                }
                                try self.fm.copyItem(at: latestDB, to: snapDB)
                                try JSONEncoder.pretty.encode(manifest).write(
                                    to: snapDir.appendingPathComponent("MANIFEST.json"),
                                    options: .atomic
                                )
                            } catch {
                                self.lastError = "latest 成功，快照失败: \(error.localizedDescription)"
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
                            let msg = "已备份到 iCloud Drive · \(snapId) · \(Self.byteString(size))"
                            print("[Backup] \(msg)")
                            completion?(true, msg)
                        }
                    }
                }
            }
        }
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
            config: config
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
