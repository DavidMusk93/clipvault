import Foundation
import CryptoKit

/// Off-site copy of a completed per-host backup. Credentials stay on the server.
final class OstoreBackup {
    static let shared = OstoreBackup()
    struct Status: Codable {
        var configured = false
        var inProgress = false
        var phase = "not_configured"
        var lastSuccessUnix: Double? = nil
        var lastError: String? = nil
        var uploaded = 0
        var skipped = 0
    }
    private struct Config: Decodable { let baseURL: String; let token: String }
    private struct Entry: Decodable { let path: String; let type: String; let sha256: String? }
    private struct Listing: Decodable { let entries: [Entry] }
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "com.clipvault.backup.ostore", qos: .utility)
    private var state = Status()
    private var pending: URL?
    private var configURL: URL { DatabaseManager.resolveDataRoot().appendingPathComponent("config/ostore-backup.json") }

    func status() -> Status {
        lock.lock(); defer { lock.unlock() }
        var result = state
        result.configured = (try? loadConfig()) != nil
        return result
    }

    func enqueue(root: URL) -> Bool {
        guard (try? loadConfig()) != nil else { return false }
        lock.lock()
        if state.inProgress { pending = root; lock.unlock(); return true }
        state.inProgress = true; state.phase = "queued"; state.lastError = nil
        lock.unlock()
        NotificationCenter.default.post(name: CloudDocsBackupService.statusChangedNotification, object: nil)
        worker.async { self.run(root: root) }
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
    private func update(_ f: (inout Status) -> Void) { lock.lock(); f(&state); lock.unlock() }
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
    private func run(root: URL) {
        let fm = FileManager.default
        let work = DatabaseManager.resolveDataRoot().appendingPathComponent(".backup_work/ostore-" + UUID().uuidString)
        defer {
            try? fm.removeItem(at: work)
            lock.lock()
            let next = pending; pending = nil
            if next == nil { state.inProgress = false }
            lock.unlock()
            NotificationCenter.default.post(name: CloudDocsBackupService.statusChangedNotification, object: nil)
            if let next = next { worker.async { self.run(root: next) } }
        }
        do {
            update { $0.phase = "prepare"; $0.uploaded = 0; $0.skipped = 0 }
            let config = try loadConfig()
            let host = ClipHostIdentity.id
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
            update { $0.phase = "upload" }
            func upload(_ local: URL, _ key: String) throws {
                let digest = try hash(local)
                if remote[key] == digest { update { $0.skipped += 1 }; return }
                let (status, data) = try request(config, path: "/api/files/" + escaped(key), method: "PUT", file: local)
                guard (200..<300).contains(status) else { throw failure("ostore 上传失败 HTTP \(status)") }
                struct Reply: Decodable { let sha256: String }
                guard let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.sha256 == digest else { throw failure("ostore 上传校验失败") }
                update { $0.uploaded += 1 }
            }
            for name in names { try upload(source.appendingPathComponent("blobs/" + name), prefix + "/blobs/" + name) }
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
            update { $0.phase = "ok"; $0.lastSuccessUnix = Date().timeIntervalSince1970; $0.lastError = nil }
        } catch {
            update { $0.phase = "error"; $0.lastError = error.localizedDescription }
            print("[OstoreBackup] \(error.localizedDescription)")
        }
    }
}
