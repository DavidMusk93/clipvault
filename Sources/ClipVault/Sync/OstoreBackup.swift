import Foundation
import CryptoKit

/// Off-site copy of a completed per-host backup. Credentials stay on the server.
final class OstoreBackup {
    static let shared = OstoreBackup()

    /// One finished run. Persisted so the panel still shows numbers after a restart.
    struct Run: Codable {
        var phase = "ok"            // ok | error
        var host: String? = nil
        var total = 0
        var uploaded = 0
        var skipped = 0
        var failed = 0
        var uploadedBytes = 0
        var skippedBytes = 0
        var remoteObjects = 0
        var remoteBytes = 0
        var startedUnix: Double? = nil
        var finishedUnix: Double? = nil
        var durationSeconds: Double? = nil
        var error: String? = nil
    }

    struct Status: Codable {
        var configured = false
        /// Mirror step on/off (`enabled` in ostore-backup.json, default true).
        var enabled = true
        var baseURL: String? = nil
        var inProgress = false
        /// Another root is waiting behind the running one (click while uploading).
        var queued = false
        var phase = "not_configured"
        var host: String? = nil
        var lastSuccessUnix: Double? = nil
        var lastError: String? = nil
        /// Objects this run intends to publish: blobs + database copies + latest files.
        var total = 0
        var uploaded = 0
        var skipped = 0
        var failed = 0
        /// Not published yet. 0 after a clean run, > 0 only after an abort.
        var pending = 0
        var uploadedBytes = 0
        var skippedBytes = 0
        /// Local manifest totals (what a restore expects).
        var manifestObjects = 0
        var manifestBytes = 0
        /// Remote listing totals under the host prefix, re-read at the end of a run.
        var remoteObjects = 0
        var remoteBytes = 0
        var startedUnix: Double? = nil
        var durationSeconds: Double? = nil
        /// Last finished run (ok or error). Persisted across restarts.
        var lastRun: Run? = nil
    }

    private struct Config: Decodable { let baseURL: String; let token: String; let enabled: Bool? }
    private struct Entry: Decodable { let path: String; let type: String; let sha256: String?; let size: Int? }
    private struct Listing: Decodable { let entries: [Entry] }
    private struct Persisted: Codable {
        var lastSuccessUnix: Double?
        var lastRun: Run?
    }

    private let lock = NSLock()
    private let worker = DispatchQueue(label: "com.clipvault.backup.ostore", qos: .utility)
    private var state = Status()
    private var pending: URL?
    /// Progress pings are coalesced: an upload run must not flood the SSE/status plane.
    private var lastPing: Double = 0
    private let pingInterval: Double = 2
    private var configURL: URL { DatabaseManager.resolveDataRoot().appendingPathComponent("config/ostore-backup.json") }
    private var stateURL: URL { DatabaseManager.resolveDataRoot().appendingPathComponent("config/ostore-backup.state.json") }

    private init() {
        // Restore the last finished run so the panel keeps its numbers across restarts.
        guard let data = try? Data(contentsOf: stateURL),
              let saved = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        state.lastSuccessUnix = saved.lastSuccessUnix
        state.lastRun = saved.lastRun
        if let run = state.lastRun {
            state.phase = run.phase
            state.host = run.host
            state.remoteObjects = run.remoteObjects
            state.remoteBytes = run.remoteBytes
            state.manifestObjects = 0
        }
    }

    func status() -> Status {
        lock.lock(); defer { lock.unlock() }
        var result = state
        let config = try? loadConfig()
        result.configured = config != nil
        result.enabled = config?.enabled ?? true
        result.baseURL = config?.baseURL
        result.queued = pending != nil
        result.pending = max(0, result.total - result.uploaded - result.skipped - result.failed)
        return result
    }

    func enqueue(root: URL) -> Bool {
        guard let config = try? loadConfig(), config.enabled != false else { return false }
        lock.lock()
        if state.inProgress { pending = root; lock.unlock(); return true }
        state.inProgress = true; state.phase = "queued"; state.lastError = nil
        lock.unlock()
        post()
        worker.async { self.run(root: root) }
        return true
    }

    /// Toggle the mirror step from the panel switch. Writes `enabled` back into the
    /// same 0600 config file and keeps baseURL / token (and any unknown keys) intact.
    @discardableResult
    func setEnabled(_ on: Bool) -> Bool {
        let url = configURL
        guard let data = try? Data(contentsOf: url),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        obj["enabled"] = on
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return false }
        guard (try? out.write(to: url, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if !on {
            lock.lock(); pending = nil; lock.unlock()
        }
        post()
        return true
    }

    private func loadConfig() throws -> Config {
        let c = try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL))
        guard let u = URL(string: c.baseURL), u.scheme == "https", u.host != nil, !c.token.isEmpty else {
            throw failure("无效的 ostore 配置（必须使用 HTTPS）")
        }
        return c
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "ClipVault.OstoreBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Mutate the live counters and ping the UI at most once per `pingInterval`.
    private func bump(_ f: (inout Status) -> Void) {
        lock.lock()
        f(&state)
        let now = Date().timeIntervalSince1970
        let ping = now - lastPing >= pingInterval
        if ping { lastPing = now }
        lock.unlock()
        if ping { post() }
    }

    /// Mutate without pinging (phase transitions post explicitly).
    private func update(_ f: (inout Status) -> Void) {
        lock.lock(); f(&state); lock.unlock()
    }

    private func post() {
        NotificationCenter.default.post(name: CloudDocsBackupService.statusChangedNotification, object: nil)
    }

    private func hash(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        var s = SHA256()
        while true { let d = h.readData(ofLength: 1024 * 1024); if d.isEmpty { break }; s.update(data: d) }
        return s.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func request(_ config: Config, path: String, method: String = "GET", file: URL? = nil) throws -> (Int, Data) {
        guard let url = URL(string: config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else { throw failure("无效 URL") }
        var req = URLRequest(url: url, timeoutInterval: 300)
        req.httpMethod = method; req.setValue("Bearer " + config.token, forHTTPHeaderField: "Authorization")
        let sem = DispatchSemaphore(value: 0)
        var response: URLResponse?; var body: Data?; var error: Error?
        let done: (Data?, URLResponse?, Error?) -> Void = { d, r, e in body = d; response = r; error = e; sem.signal() }
        let task = file.map { URLSession.shared.uploadTask(with: req, fromFile: $0, completionHandler: done) }
            ?? URLSession.shared.dataTask(with: req, completionHandler: done)
        task.resume(); sem.wait()
        if let error = error { throw error }
        guard let http = response as? HTTPURLResponse else { throw failure("ostore 无响应") }
        return (http.statusCode, body ?? Data())
    }
    private func escaped(_ s: String) -> String {
        s.split(separator: "/", omittingEmptySubsequences: false).map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? ""
        }.joined(separator: "/")
    }
    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Freeze the live counters into `lastRun` and persist them.
    private func finish(ok: Bool, started: Double, error: String?, remote: (objects: Int, bytes: Int)?) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        state.phase = ok ? "ok" : "error"
        state.lastError = error
        state.durationSeconds = now - started
        if ok { state.lastSuccessUnix = now }
        if let remote = remote { state.remoteObjects = remote.objects; state.remoteBytes = remote.bytes }
        var run = Run()
        run.phase = state.phase
        run.host = state.host
        run.total = state.total
        run.uploaded = state.uploaded
        run.skipped = state.skipped
        run.failed = state.failed
        run.uploadedBytes = state.uploadedBytes
        run.skippedBytes = state.skippedBytes
        run.remoteObjects = state.remoteObjects
        run.remoteBytes = state.remoteBytes
        run.startedUnix = started
        run.finishedUnix = now
        run.durationSeconds = now - started
        run.error = error
        state.lastRun = run
        let saved = Persisted(lastSuccessUnix: state.lastSuccessUnix, lastRun: run)
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(saved) {
            let url = stateURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        UiMetrics.shared.emit("backup_ostore_run", durMs: (now - started) * 1000, ok: ok,
                              payload: ["n": run.total, "bytes": run.uploadedBytes,
                                        "applied": run.uploaded, "reused": run.skipped,
                                        "miss": run.failed])
        post()
    }

    private func run(root: URL) {
        let fm = FileManager.default
        let work = DatabaseManager.resolveDataRoot().appendingPathComponent(".backup_work/ostore-" + UUID().uuidString)
        let started = Date().timeIntervalSince1970
        defer {
            try? fm.removeItem(at: work)
            lock.lock()
            let next = pending; pending = nil
            if next == nil { state.inProgress = false }
            lock.unlock()
            post()
            if let next = next { worker.async { self.run(root: next) } }
        }
        do {
            let host = ClipHostIdentity.id
            update {
                $0.phase = "prepare"; $0.host = host; $0.lastError = nil
                $0.total = 0; $0.uploaded = 0; $0.skipped = 0; $0.failed = 0; $0.pending = 0
                $0.uploadedBytes = 0; $0.skippedBytes = 0
                $0.manifestObjects = 0; $0.manifestBytes = 0
                $0.remoteObjects = 0; $0.remoteBytes = 0
                $0.startedUnix = started; $0.durationSeconds = nil
            }
            lock.lock(); lastPing = 0; lock.unlock()  // first counter change pings immediately
            post()
            let config = try loadConfig()
            guard !host.isEmpty, host != ".", host != "..", !host.contains("/") else { throw failure("无效 hostId") }
            let source = root.appendingPathComponent("hosts/" + host)
            let manifestURL = source.appendingPathComponent("latest/MANIFEST.json")
            let manifestData = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(CloudDocsBackupService.Manifest.self, from: manifestData)
            guard manifest.host == host, manifest.blobsVerified == true, let names = manifest.blobFiles, manifest.blobCount == names.count else { throw failure("本地备份清单不完整") }
            guard Set(names).count == names.count, names.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else { throw failure("备份清单包含无效文件名") }
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let db = work.appendingPathComponent("clipflow.db")
            try fm.copyItem(at: source.appendingPathComponent("latest/clipflow.db"), to: db)
            guard try hash(db) == manifest.sha256 else { throw failure("备份数据库与清单不一致，请重试") }
            let m = work.appendingPathComponent("MANIFEST.json"); try manifestData.write(to: m)
            let prefix = "clipvault/backup/hosts/" + host
            bump {
                $0.manifestObjects = names.count
                $0.manifestBytes = manifest.blobBytes ?? 0
                $0.total = names.count + 3  // blobs + databases/SHA.db + latest/clipflow.db + latest/MANIFEST.json
            }
            let (code, data) = try request(config, path: "/api/list?path=" + escaped(prefix) + "&recursive=1&checksums=1")
            var remote: [String: String] = [:]
            if code == 200 {
                for entry in try JSONDecoder().decode(Listing.self, from: data).entries where entry.type == "file" { remote[entry.path] = entry.sha256 }
            } else if code != 404 { throw failure("ostore 列表失败 HTTP \(code)") }
            var previousDB: String?
            if remote[prefix + "/latest/MANIFEST.json"] != nil {
                let (status, oldData) = try request(config, path: "/api/files/" + escaped(prefix + "/latest/MANIFEST.json"))
                guard status == 200, let old = try? JSONDecoder().decode(CloudDocsBackupService.Manifest.self, from: oldData), old.host == host else { throw failure("远程备份清单无效") }
                previousDB = old.sha256
            }
            bump { $0.phase = "upload" }
            func upload(_ local: URL, _ key: String) throws {
                let size = fileSize(local)
                let digest = try hash(local)
                if remote[key] == digest {
                    bump { $0.skipped += 1; $0.skippedBytes += size }
                    return
                }
                let (status, data) = try request(config, path: "/api/files/" + escaped(key), method: "PUT", file: local)
                guard (200..<300).contains(status) else { throw failure("ostore 上传失败 HTTP \(status)") }
                struct Reply: Decodable { let sha256: String }
                guard let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.sha256 == digest else { throw failure("ostore 上传校验失败") }
                bump { $0.uploaded += 1; $0.uploadedBytes += size }
            }
            let uploads = OperationQueue()
            uploads.maxConcurrentOperationCount = 8
            let errorLock = NSLock()
            var firstError: Error?
            for name in names {
                uploads.addOperation {
                    errorLock.lock(); let failed = firstError != nil; errorLock.unlock()
                    if failed { return }
                    do { try upload(source.appendingPathComponent("blobs/" + name), prefix + "/blobs/" + name) }
                    catch {
                        errorLock.lock()
                        if firstError == nil { firstError = error }
                        errorLock.unlock()
                        self.bump { $0.failed += 1 }
                    }
                }
            }
            uploads.waitUntilAllOperationsAreFinished()
            if let error = firstError { throw error }
            try upload(db, prefix + "/databases/" + manifest.sha256 + ".db")
            try upload(db, prefix + "/latest/clipflow.db")
            try upload(m, prefix + "/latest/MANIFEST.json")
            // Retain the current and prior database copies. Prune only known hash keys
            // after publishing the new manifest; never remove CAS blobs here.
            let dbPrefix = prefix + "/databases/"
            for key in remote.keys where key.hasPrefix(dbPrefix) {
                let name = String(key.dropFirst(dbPrefix.count))
                let digest = name.hasSuffix(".db") ? String(name.dropLast(3)) : ""
                guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }), digest != manifest.sha256, digest != previousDB else { continue }
                let (status, _) = try request(config, path: "/api/files/" + escaped(key), method: "DELETE")
                guard (200..<300).contains(status) else { throw failure("ostore 清理旧数据库失败 HTTP \(status)") }
            }
            // One extra listing so the panel can show what actually sits off-site
            // instead of only what this run moved. Never fails the run.
            var remoteTotals: (objects: Int, bytes: Int)?
            if let (rcode, rdata) = try? request(config, path: "/api/list?path=" + escaped(prefix) + "&recursive=1"), rcode == 200,
               let entries = try? JSONDecoder().decode(Listing.self, from: rdata).entries {
                let files = entries.filter { $0.type == "file" }
                remoteTotals = (files.count, files.reduce(0) { $0 + ($1.size ?? 0) })
            }
            finish(ok: true, started: started, error: nil, remote: remoteTotals)
        } catch {
            finish(ok: false, started: started, error: error.localizedDescription, remote: nil)
            print("[OstoreBackup] \(error.localizedDescription)")
        }
    }
}
