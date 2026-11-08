import Foundation
import CryptoKit

/// HTTP + SSE wire for the **ostore** transport of the live sync plane.
///
/// One object store becomes the shared bus for the per-host transaction log that
/// `CloudDocsSyncService` already produces. The wire itself is transport-pure: it
/// lists, puts, batches, gets and follows the object event stream. Merging,
/// cursors and conflict rules stay in `CloudDocsSyncService` (one owner).
///
/// ```text
///   {prefix}/trx/{host}/{seq:016d}.json   transaction log (same JSON as iCloud)
///   {prefix}/attach/{key}.bin             attachments named by the op's blob_keys
///   {prefix}/heads/{host}.json            liveness + highest published seq
///
///   capture → POST /api/batch (one RTT) → object.created event
///                                              │  SSE  < 1 s
///                                              v
///   peer pull → GET trx + GET attach → apply → wall SSE
/// ```
///
/// Credentials are the ones the cold backup already uses
/// (`config/ostore-backup.json`, 0600): `{baseURL, token, enabled}`. Never logged.
final class OstoreSyncWire {
    struct Config: Equatable {
        var baseURL: String
        var token: String
    }

    struct Entry {
        var path: String
        var type: String
        var size: Int
        var md5: String?
        var sha256: String?
    }

    struct PutReply {
        var md5: String?
        var sha256: String?
        var size: Int?
    }

    struct BatchItem {
        var path: String
        var data: Data
    }

    struct BatchReply {
        var written: [String: PutReply]
        var failed: [String: String]
    }

    struct ObjectEvent {
        var id: UInt64?
        var kind: String
        var path: String
        var from: String?
    }

    struct WireError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Server caps `POST /api/batch` at 256 objects / 16 MiB. Stay under both and
    /// keep a batch small enough that a retry after a timeout is cheap.
    static let batchMaxObjects = 96
    static let batchMaxBytes = 6 * 1024 * 1024

    let prefix: String
    private let config: Config
    private let session: URLSession
    private var batchUnsupported = false
    private var streamTask: Task<Void, Never>?
    private var streamGeneration = 0
    private let lock = NSLock()

    // MARK: Config

    /// Same file the ostore cold backup reads. The `enabled` flag belongs to the
    /// backup mirror only — the transport must not silently stop because the user
    /// paused cold backups, so it is deliberately ignored here.
    static func loadConfig() -> Config? {
        let url = DatabaseManager.resolveDataRoot()
            .appendingPathComponent("config/ostore-backup.json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let base = obj["baseURL"] as? String,
              let token = obj["token"] as? String,
              !token.isEmpty,
              let parsed = URL(string: base),
              parsed.scheme == "https",
              parsed.host != nil
        else { return nil }
        return Config(baseURL: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")), token: token)
    }

    init?(prefix: String, config: Config? = nil) {
        guard let c = config ?? Self.loadConfig() else { return nil }
        self.config = c
        self.prefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 120
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
    }

    var baseHost: String { URL(string: config.baseURL)?.host ?? "" }

    // MARK: Paths

    func trxPath(host: String, seq: Int) -> String {
        "\(prefix)/trx/\(host)/\(String(format: "%016d", seq)).json"
    }

    func attachedPath(key: String) -> String { "\(prefix)/attach/\(key).bin" }

    func headPath(host: String) -> String { "\(prefix)/heads/\(host).json" }

    /// `trx/{host}/{seq}.json` → (host, seq). nil for anything else.
    func parseTrxPath(_ path: String) -> (host: String, seq: Int)? {
        let head = "\(prefix)/trx/"
        guard path.hasPrefix(head) else { return nil }
        let rest = path.dropFirst(head.count).split(separator: "/")
        guard rest.count == 2 else { return nil }
        let name = rest[1]
        guard name.hasSuffix(".json"),
              let seq = Int(name.dropLast(5)), seq > 0 else { return nil }
        return (String(rest[0]), seq)
    }

    func matchesPrefix(_ path: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }

    // MARK: Requests

    private func escaped(_ s: String) -> String {
        s.split(separator: "/", omittingEmptySubsequences: false).map {
            String($0).addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
            ) ?? ""
        }.joined(separator: "/")
    }

    private func url(_ path: String, query: String? = nil) throws -> URL {
        var raw = config.baseURL + path
        if let query, !query.isEmpty { raw += "?" + query }
        guard let u = URL(string: raw) else { throw WireError(message: "ostore URL 无效") }
        return u
    }

    private func send(_ request: URLRequest, body: Data? = nil, fromFile: URL? = nil) throws -> (Int, Data) {
        var req = request
        req.setValue("Bearer " + config.token, forHTTPHeaderField: "Authorization")
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let sem = DispatchSemaphore(value: 0)
        var reply: Data?
        var status = 0
        var failure: Error?
        let done: (Data?, URLResponse?, Error?) -> Void = { data, response, error in
            reply = data
            failure = error
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }
        let task: URLSessionTask
        if let fromFile {
            task = session.uploadTask(with: req, fromFile: fromFile, completionHandler: done)
        } else if let body {
            task = session.uploadTask(with: req, from: body, completionHandler: done)
        } else {
            task = session.dataTask(with: req, completionHandler: done)
        }
        task.resume()
        sem.wait()
        if let failure { throw failure }
        guard status != 0 else { throw WireError(message: "ostore 无响应") }
        return (status, reply ?? Data())
    }

    // MARK: List / put / get

    /// One listing carries every object under the prefix (trx + attach + heads), so a
    /// push/pull cycle costs one round trip for discovery instead of one per object.
    /// A prefix that does not exist yet is `404` on ostore — an empty fleet, not an error.
    func list(recursive: Bool = true, checksums: Bool = true) throws -> [Entry] {
        let q = "path=" + escaped(prefix) + (recursive ? "&recursive=1" : "") + (checksums ? "&checksums=1" : "")
        let (status, data) = try send(URLRequest(url: try url("/api/list", query: q)))
        if status == 404 { return [] }
        guard status == 200 else {
            throw WireError(message: "ostore 列表 HTTP \(status)")
        }
        struct Listing: Decodable {
            struct Row: Decodable {
                let path: String
                let type: String?
                let size: Int?
                let md5: String?
                let sha256: String?
            }
            let entries: [Row]?
        }
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        return (listing.entries ?? []).map {
            Entry(path: $0.path, type: $0.type ?? "file", size: $0.size ?? 0, md5: $0.md5, sha256: $0.sha256)
        }
    }

    func put(path: String, data: Data) throws -> PutReply {
        var req = URLRequest(url: try url("/api/files/" + escaped(path)))
        req.httpMethod = "PUT"
        let (status, body) = try send(req, body: data)
        guard (200..<300).contains(status) else { throw WireError(message: "ostore 上传 HTTP \(status)") }
        return Self.decodePut(body)
    }

    func putFile(path: String, file: URL) throws -> PutReply {
        var req = URLRequest(url: try url("/api/files/" + escaped(path)))
        req.httpMethod = "PUT"
        let (status, body) = try send(req, fromFile: file)
        guard (200..<300).contains(status) else { throw WireError(message: "ostore 上传 HTTP \(status)") }
        return Self.decodePut(body)
    }

    func get(path: String) throws -> Data {
        guard let data = try getIfPresent(path: path) else {
            throw WireError(message: "ostore 下载 404 \(path)")
        }
        return data
    }

    /// `nil` when the object is not there (404); throws only on transport failures.
    /// Absence is a normal answer on the sync wire: an op the peer has not published
    /// yet, or an attachment that has not landed.
    func getIfPresent(path: String) throws -> Data? {
        let (status, body) = try send(URLRequest(url: try url("/api/files/" + escaped(path))))
        if status == 404 { return nil }
        guard status == 200 else { throw WireError(message: "ostore 下载 HTTP \(status)") }
        return body
    }

    /// Existence probe without checksums. Content-addressed paths (`attach/{sha}.bin`)
    /// make existence == identity, so this is enough to skip an upload.
    func exists(path: String) throws -> Bool {
        let q = "path=" + escaped(path) + "&checksums=0"
        let (status, _) = try send(URLRequest(url: try url("/api/stat", query: q)))
        if status == 404 { return false }
        guard status == 200 else { throw WireError(message: "ostore stat HTTP \(status)") }
        return true
    }

    private static func decodePut(_ body: Data) -> PutReply {
        struct Reply: Decodable { let md5: String?; let sha256: String?; let size: Int? }
        let r = try? JSONDecoder().decode(Reply.self, from: body)
        return PutReply(md5: r?.md5, sha256: r?.sha256, size: r?.size)
    }

    /// Publish a burst of small objects in one request (`POST /api/batch`).
    /// Returns nil when the server predates the endpoint — the caller then falls
    /// back to per-object `put`, so a ClipVault build never requires an ostore deploy
    /// to be in the same release.
    func batch(_ items: [BatchItem]) throws -> BatchReply? {
        lock.lock()
        let disabled = batchUnsupported
        lock.unlock()
        if disabled || items.isEmpty { return disabled ? nil : BatchReply(written: [:], failed: [:]) }
        let payload: [String: Any] = [
            "objects": items.map { ["path": $0.path, "data_b64": $0.data.base64EncodedString()] }
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        var req = URLRequest(url: try url("/api/batch"))
        req.httpMethod = "POST"
        let (status, reply) = try send(req, body: body)
        if status == 404 || status == 405 {
            lock.lock(); batchUnsupported = true; lock.unlock()
            return nil
        }
        guard status == 200 else { throw WireError(message: "ostore 批量上传 HTTP \(status)") }
        struct Row: Decodable { let path: String; let md5: String?; let sha256: String?; let size: Int? }
        struct Reply: Decodable { let written: [Row]?; let failed: [Fail]?
            struct Fail: Decodable { let path: String; let error: String }
        }
        let decoded = try JSONDecoder().decode(Reply.self, from: reply)
        var written: [String: PutReply] = [:]
        for row in decoded.written ?? [] {
            written[row.path] = PutReply(md5: row.md5, sha256: row.sha256, size: row.size)
        }
        var failed: [String: String] = [:]
        for row in decoded.failed ?? [] { failed[row.path] = row.error }
        return BatchReply(written: written, failed: failed)
    }

    // MARK: Event stream

    /// Follow `/api/events` scoped to `prefix`. Reconnects with backoff, resuming
    /// from `Last-Event-ID`; `onReset` tells the caller to re-list because the
    /// server could not honour the cursor.
    ///
    /// All callbacks fire on a private utility queue. Callers hop to their own queue.
    func startEvents(
        since: UInt64?,
        onEvent: @escaping (ObjectEvent) -> Void,
        onReset: @escaping () -> Void,
        onState: @escaping (Bool) -> Void
    ) {
        // Never hold `lock` across `Task.detached`: the task body takes the same
        // lock on its first generation check and would deadlock the sync queue.
        lock.lock()
        streamGeneration += 1
        let generation = streamGeneration
        streamTask?.cancel()
        streamTask = nil
        lock.unlock()
        let cfg = config
        let scope = prefix
        let prefixQuery = scope.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? scope
        let task = Task.detached(priority: .utility) { [weak self] in
            var cursor = since
            var attempt = 0
            while !Task.isCancelled {
                if self?.activeGeneration() != generation { return }
                do {
                    var raw = cfg.baseURL + "/api/events?prefix=\(prefixQuery)&replay=0"
                    if let cursor { raw = cfg.baseURL + "/api/events?prefix=\(prefixQuery)&since=\(cursor)" }
                    guard let u = URL(string: raw) else { throw WireError(message: "events URL 无效") }
                    var req = URLRequest(url: u)
                    req.setValue("Bearer " + cfg.token, forHTTPHeaderField: "Authorization")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    // Never negotiate compression on the stream: a compressing proxy
                    // (ostore itself used tower-http's CompressionLayer) buffers small
                    // frames until its window fills, which reads as a dead EventSource.
                    req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    req.timeoutInterval = 25  // ostore pings every 15 s
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard code == 200 else { throw WireError(message: "events HTTP \(code)") }
                    print("[Sync] ostore stream open · \(raw)")
                    onState(true)
                    attempt = 0
                    // Frame framing is a **blank line**. Split the byte stream here
                    // rather than through `bytes.lines`: the empty delimiter line must be
                    // observable, and a lost blank line silently loses every frame.
                    var kind = ""
                    var dataLine = ""
                    func dispatchFrame() {
                        defer { kind = ""; dataLine = "" }
                        guard !dataLine.isEmpty else { return }
                        if kind == "stream.reset" {
                            cursor = nil
                            onReset()
                            return
                        }
                        guard let ev = Self.decodeEvent(kind: kind, data: dataLine) else { return }
                        if let id = ev.id { cursor = id }
                        var copy = ev
                        if let decoded = ev.path.removingPercentEncoding { copy.path = decoded }
                        onEvent(copy)
                    }
                    var lineBuf: [UInt8] = []
                    lineBuf.reserveCapacity(512)
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        guard byte == 0x0A else {
                            lineBuf.append(byte)
                            continue
                        }
                        var line = String(decoding: lineBuf, as: UTF8.self)
                        lineBuf.removeAll(keepingCapacity: true)
                        if line.hasSuffix("\r") { line.removeLast() }
                        if line.isEmpty { dispatchFrame(); continue }
                        if line.hasPrefix(":") { continue }        // keep-alive comment
                        if line.hasPrefix("id:") {
                            let v = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                            if let n = UInt64(v) { cursor = n }
                        } else if line.hasPrefix("event:") {
                            kind = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            dataLine = String(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
                        }
                    }
                } catch {
                    if Task.isCancelled { return }
                    print("[Sync] ostore stream error: \(error.localizedDescription) — will retry")
                }
                if Task.isCancelled { return }
                onState(false)
                attempt = min(attempt + 1, 5)
                let backoff = [400, 800, 1600, 3200, 5000][max(0, min(attempt - 1, 4))]
                try? await Task.sleep(nanoseconds: UInt64(backoff + Int.random(in: 0...300)) * 1_000_000)
            }
        }
        lock.lock()
        if streamGeneration == generation { streamTask = task } else { task.cancel() }
        lock.unlock()
    }

    func stopEvents() {
        lock.lock()
        streamGeneration += 1
        streamTask?.cancel()
        streamTask = nil
        lock.unlock()
    }

    private func activeGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        return streamGeneration
    }

    private static func decodeEvent(kind: String, data: String) -> ObjectEvent? {
        guard let raw = data.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let path = obj["path"] as? String else { return nil }
        let id = (obj["id"] as? NSNumber)?.uint64Value
        return ObjectEvent(
            id: id,
            kind: kind.isEmpty ? (obj["event"] as? String ?? "") : kind,
            path: path,
            from: obj["from"] as? String
        )
    }

    // MARK: Digest

    static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Attachment identity (the key *is* this digest).
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
