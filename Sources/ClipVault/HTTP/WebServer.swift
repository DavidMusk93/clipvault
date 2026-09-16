import Foundation
import Network
import AppKit
import ImageIO
import CoreGraphics
import CryptoKit

class WebServer {
    /// Public path on xyz69.top; local :80 stays `/`. Incoming `/clipvault` is stripped.
    static let publicPathPrefix = "/clipvault"

    static func requestHeaders(_ lines: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            out[name] = value
        }
        return out
    }

    static func isLoopbackRequest(_ headers: [String: String]) -> Bool {
        let host = (headers["host"] ?? "").lowercased()
        let name = host.split(separator: ":").first.map(String.init) ?? host
        if name == "127.0.0.1" || name == "localhost" || name == "::1" || name == "[::1]" {
            return true
        }
        // Cloudflare / other reverse proxies must not inherit loopback via X-Forwarded-For.
        return false
    }

    /// Public tunnel hosts are closed unless a TOTP session cookie, Cloudflare Access JWT,
    /// or optional CLIPVAULT_ORIGIN_TOKEN (scripts) is present.
    static func publicRequestAuthorized(_ headers: [String: String]) -> Bool {
        if ClipVaultAuth.shared.isSessionAuthorized(headers) { return true }
        guard let token = ProcessInfo.processInfo.environment["CLIPVAULT_ORIGIN_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return false
        }
        if headers["x-clipvault-token"] == token { return true }
        let auth = headers["authorization"] ?? ""
        if auth == "Bearer \(token)" { return true }
        return false
    }

    static func stripPublicPrefix(_ path: String) -> String {
        let p = publicPathPrefix
        if path == p { return "/" }
        if path.hasPrefix(p + "/") {
            let rest = String(path.dropFirst(p.count))
            return rest.isEmpty ? "/" : rest
        }
        if path.hasPrefix(p + "?") {
            return "/" + String(path.dropFirst(p.count))
        }
        return path
    }

    static func tlsEnabled() -> Bool {
        let v = ProcessInfo.processInfo.environment["CLIPVAULT_TLS"] ?? "0"
        return v == "1" || v == "true" || v == "TRUE" || v == "yes" || v == "on"
    }

    private var originStarted = false
    private let port: UInt16
    private let tls: Bool
    private let database: DatabaseManager
    private let backup: CloudDocsBackupService?
    private let sync: CloudDocsSyncService?
    private let archive: WebArchiveService?
    /// Control-plane SSE: one EventSource, comment+data heartbeat, bounded
    /// per-client buffer. Overflow coalesces to `resync_required` (never silent drop).
    private final class SSESession {
        let connection: HTTPByteSink
        var queue: [Data] = []
        var inflight = false
        var resyncRequired = false
        var dead = false
        init(_ connection: HTTPByteSink) { self.connection = connection }
    }
    private let sseQueue = DispatchQueue(label: "clipvault.sse")
    private var sseSessions: [ObjectIdentifier: SSESession] = [:]
    private var sseHeartbeat: DispatchSourceTimer?
    private var procTimer: DispatchSourceTimer?
    private var lastProc: [String: Int] = [:]
    private static let sseMaxBuffered = 32
    private static let sseHeartbeatSeconds: Int = 15
    private static let sseResyncFrame = Data("data: {\"type\":\"resync_required\"}\n\n".utf8)
    private static let ssePingFrame = Data(": ping\n\ndata: {\"type\":\"ping\"}\n\n".utf8)
    
    var isRunning: Bool { originStarted }

    init(
        port: UInt16 = 80,
        database: DatabaseManager = DatabaseManager(),
        backup: CloudDocsBackupService? = nil,
        sync: CloudDocsSyncService? = nil,
        archive: WebArchiveService? = nil
    ) {
        self.port = port
        self.tls = Self.tlsEnabled()
        self.database = database
        self.backup = backup
        self.sync = sync
        self.archive = archive
        archive?.onFinished = { [weak self] itemId, _, err in
            self?.broadcastSSE(event: err == nil ? "archive_ok" : "archive_error", id: itemId)
        }
    }
    
    /// Resolve web/ by cwd first, then walk up from executable (LaunchAgent-safe).
    private func projectWebDirectory() -> String? {
        let fm = FileManager.default
        let cwdWeb = fm.currentDirectoryPath + "/web"
        if fm.fileExists(atPath: cwdWeb + "/index.html") { return cwdWeb }

        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("web")
            if fm.fileExists(atPath: candidate.appendingPathComponent("index.html").path) {
                return candidate.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    func start() {
        guard !originStarted else { return }
        originStarted = true
        let sock = DatabaseManager.resolveDataRoot()
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("http.sock")
        OriginUnixServer.shared.start(path: sock.path) { [weak self] sink in
            self?.receiveRequest(from: sink)
        }
        let listen = ProcessInfo.processInfo.environment["CLIPVAULT_LISTEN"]
            ?? "127.0.0.1:\(port),[::1]:\(port)"
        HttpFrontProcess.shared.start(originSock: sock.path, listen: listen, tls: tls)
        TraeAskFanIn.shared.attach(self)
        let scheme = tls ? "https" : "http"
        let host = (port == 80 && !tls) || (port == 443 && tls)
            ? "127.0.0.1"
            : "127.0.0.1:\(port)"
        print("Web origin CV01 \(sock.path); browser \(scheme)://\(host)/ (HTTP/2)")
        sseQueue.async { [weak self] in
            self?.startProcSamplerLocked()
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name("ClipVaultItemAdded"),
            object: nil,
            queue: nil
        ) { [weak self] note in
            let id: String? = {
                if let item = note.object as? ClipboardItem { return item.id.uuidString }
                if let uuid = note.object as? UUID { return uuid.uuidString }
                if let s = note.object as? String, !s.isEmpty { return s }
                return nil
            }()
            self?.broadcastSSE(event: "update", id: id)
        }
        NotificationCenter.default.addObserver(
            forName: .clipFlowOCRReady,
            object: nil,
            queue: nil
        ) { [weak self] note in
            let id = (note.object as? UUID)?.uuidString
            self?.broadcastSSE(event: "ocr_ready", id: id)
        }
        NotificationCenter.default.addObserver(
            forName: CloudDocsBackupService.statusChangedNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.broadcastSSE(event: "backup_status")
        }
    }
    
    func stop() {
        HttpFrontProcess.shared.stop()
        OriginUnixServer.shared.stop()
        originStarted = false
        sseQueue.async { [weak self] in
            self?.procTimer?.cancel()
            self?.procTimer = nil
            self?.teardownSSELocked()
        }
    }
    
    private func receiveRequest(from connection: HTTPByteSink) {
        accumulateRequest(from: connection, buffer: Data())
    }

    private static let maxRequestBytes = 8 * 1024 * 1024

    private func accumulateRequest(from connection: HTTPByteSink, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buf = buffer
            if let data, !data.isEmpty { buf.append(data) }
            if buf.count > Self.maxRequestBytes {
                self.sendErrorResponse(connection: connection, status: 413, message: "Payload Too Large")
                return
            }
            if buf.count >= 4 && !OriginWire.looksLikeCV01(buf) {
                self.sendErrorResponse(connection: connection, status: 400, message: "Bad Request")
                return
            }
            if let (req, _) = OriginWire.decodeRequest(from: buf) {
                if req.method.isEmpty {
                    self.sendErrorResponse(connection: connection, status: 400, message: "Bad Request")
                    return
                }
                self.handleRequest(req, connection: connection)
                return
            }
            if isComplete || error != nil {
                if buf.isEmpty {
                    connection.cancel()
                    return
                }
                self.sendErrorResponse(connection: connection, status: 400, message: "Bad Request")
                return
            }
            self.accumulateRequest(from: connection, buffer: buf)
        }
    }

    private func handleRequest(_ req: OriginWire.Request, connection: HTTPByteSink) {
        let method = req.method
        let path = Self.stripPublicPrefix(req.path)
        let headers = req.headers
        let data = req.body
        let pathOnly = path.split(separator: "?", maxSplits: 1).map(String.init).first ?? path
        let loopback = Self.isLoopbackRequest(headers)

        if pathOnly == "/login/setup" {
            if !loopback {
                sendErrorResponse(connection: connection, status: 404, message: "Not Found")
                return
            }
            sendLoginHTML(ClipVaultAuth.shared.setupPageHTML(), connection: connection)
            return
        }
        if pathOnly == "/login" {
            handleLogin(method: method, data: data, connection: connection)
            return
        }
        if pathOnly == "/logout" {
            handleLogout(connection: connection)
            return
        }

        if pathOnly == "/trae" || pathOnly.hasPrefix("/trae/") {
            if !loopback {
                sendErrorResponse(connection: connection, status: 404, message: "Not Found")
                return
            }
            handleTraeProxy(
                path: path,
                connection: connection,
                method: method,
                data: data,
                headers: headers
            )
            return
        }

        if method == "GET" || method == "HEAD" {
            if pathOnly.hasPrefix("/s/") {
                handleSharePage(pathOnly: pathOnly, connection: connection)
                return
            }
            if pathOnly == "/api/share/asset" {
                handleShareAsset(path: path, connection: connection)
                return
            }
            if pathOnly.hasPrefix("/assets/") {
                sendStaticAsset(pathOnly: pathOnly, connection: connection)
                return
            }
        }

        if !loopback, !Self.publicRequestAuthorized(headers) {
            sendUnauthorized(connection: connection, path: pathOnly)
            return
        }

        if method == "OPTIONS" {
            handleOptionsRequest(connection: connection)
        } else if method == "GET" || method == "HEAD" {
            handleGetRequest(path: path, connection: connection)
        } else if method == "POST" && pathOnly == "/api/clips" {
            handlePostClip(data: data, connection: connection)
        } else if method == "POST" && pathOnly == "/api/backup/config" {
            handleBackupConfig(data: data, connection: connection)
        } else if method == "POST" && pathOnly == "/api/backup/run" {
            handleBackupRun(connection: connection)
        } else if method == "POST" && pathOnly == "/api/backup/restore" {
            handleBackupRestore(data: data, connection: connection)
        } else if method == "POST" && pathOnly == "/api/sync/now" {
            handleSyncNow(connection: connection)
        } else if method == "POST" && pathOnly == "/api/sync/config" {
            handleSyncConfig(data: data, connection: connection)
        } else if method == "POST" && pathOnly == "/api/clips/restore" {
            handleRestoreClip(data: data, connection: connection)
        } else if method == "POST" && pathOnly == "/api/clips/context" {
            handleClipContext(data: data, connection: connection)
        } else if method == "POST" && pathOnly == "/api/clips/evaluate" {
            handleClipEvaluate(data: data, connection: connection)
        } else if method == "POST" && pathOnly == "/api/archive" {
            handleArchivePost(data: data, connection: connection)
        } else if method == "POST" && pathOnly == "/api/archive/reader" {
            handleReaderPost(data: data, connection: connection)
        } else if method == "POST" && pathOnly == "/api/compose" {
            handleComposeSave(data: data, connection: connection)
        } else if method == "POST" && pathOnly == "/api/compose/image" {
            handleComposeImage(data: data, connection: connection)
        } else if method == "POST" && pathOnly == "/api/ui-metrics" {
            handleUiMetricsIngest(data: data, connection: connection)
        } else if method == "POST" && pathOnly == "/api/clips/pin" {
            handleClipPin(data: data, connection: connection)
        } else if method == "POST" && pathOnly == "/api/share" {
            handleShareCreate(data: data, headers: headers, connection: connection)
        } else if method == "POST" && pathOnly == "/api/share/revoke" {
            handleShareRevoke(data: data, connection: connection)
        } else if method == "POST" && pathOnly == "/api/clips/link" {
            handleClipLink(data: data, connection: connection)
        } else if method == "DELETE" && pathOnly.hasPrefix("/api/archive") {
            handleArchiveClear(path: path, connection: connection)
        } else if method == "DELETE" && pathOnly.hasPrefix("/api/clips") {
            handleDeleteClip(path: path, connection: connection)
        } else {
            sendErrorResponse(connection: connection, status: 405, message: "Method Not Allowed")
        }
    }
    
    private func sendUnauthorized(connection: HTTPByteSink, path: String) {
        if path.hasPrefix("/api/") {
            let body = Data(#"{"error":"unauthorized"}"#.utf8)
            sendBinary(
                status: 401,
                reason: "Unauthorized",
                contentType: "application/json",
                body: body,
                connection: connection,
                extraHeaders: [("Cache-Control", "no-store")]
            )
            return
        }
        sendBinary(
            status: 302,
            reason: "Found",
            contentType: "text/html; charset=utf-8",
            body: Data(),
            connection: connection,
            extraHeaders: [
                ("Location", "\(Self.publicPathPrefix)/login"),
                ("Cache-Control", "no-store"),
            ]
        )
    }

    private func sendLoginHTML(_ html: String, connection: HTTPByteSink) {
        sendBinary(
            status: 200,
            reason: "OK",
            contentType: "text/html; charset=utf-8",
            body: Data(html.utf8),
            connection: connection,
            extraHeaders: [("Cache-Control", "no-store")]
        )
    }

    private func handleLogin(method: String, data: Data, connection: HTTPByteSink) {
        if method == "GET" || method == "HEAD" {
            sendLoginHTML(ClipVaultAuth.shared.loginPageHTML(error: nil), connection: connection)
            return
        }
        guard method == "POST" else {
            sendErrorResponse(connection: connection, status: 405, message: "Method Not Allowed")
            return
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        let code = Self.formQueryValue(path: "?\(body)", name: "code") ?? ""
        if ClipVaultAuth.shared.verifyCode(code) {
            sendBinary(
                status: 302,
                reason: "Found",
                contentType: "text/html; charset=utf-8",
                body: Data(),
                connection: connection,
                extraHeaders: [
                    ("Location", "\(Self.publicPathPrefix)/"),
                    ("Set-Cookie", ClipVaultAuth.shared.newSessionCookie()),
                    ("Cache-Control", "no-store"),
                ]
            )
            return
        }
        sendLoginHTML(ClipVaultAuth.shared.loginPageHTML(error: "验证码不对或尝试太多次，请再试。"), connection: connection)
    }

    private func handleLogout(connection: HTTPByteSink) {
        let clear = "\(ClipVaultAuth.cookieName)=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax"
        sendBinary(
            status: 302,
            reason: "Found",
            contentType: "text/html; charset=utf-8",
            body: Data(),
            connection: connection,
            extraHeaders: [
                ("Location", "\(Self.publicPathPrefix)/login"),
                ("Set-Cookie", clear),
                ("Cache-Control", "no-store"),
            ]
        )
    }

    private func handleOptionsRequest(connection: HTTPByteSink) {
        sendBinary(
            status: 204,
            reason: "No Content",
            contentType: "text/plain",
            body: Data(),
            connection: connection,
            extraHeaders: [
                ("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS"),
                ("Access-Control-Allow-Headers", "Content-Type"),
                ("Cache-Control", "no-store"),
            ]
        )
    }

    /// `URLComponents.queryItems` is RFC 3986: `+` stays `+`.
    /// Browsers' `URLSearchParams` is form-urlencoded: space → `+`.
    /// Decode `q=ssh+localhost` as `ssh localhost` without turning `c%2B%2B` into spaces.
    static func formQueryValue(path: String, name: String) -> String? {
        guard let qMark = path.firstIndex(of: "?") else { return nil }
        let qs = path[path.index(after: qMark)...]
        for pair in qs.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == name else { continue }
            return String(parts[1])
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding
        }
        return nil
    }

    private func handleGetRequest(path: String, connection: HTTPByteSink) {
        // path may include query string, e.g. /api/clips?cursor=...
        let pathOnly = path.split(separator: "?", maxSplits: 1).map(String.init).first ?? path
        if pathOnly == "/" || pathOnly == "/index.html" {
            sendHTMLResponse(connection: connection)
        } else if pathOnly == "/notes" || pathOnly == "/notes.html" {
            sendWebFile("notes.html", connection: connection)
        } else if pathOnly == "/api/items" || pathOnly == "/api/clips" {
            sendItemsJSON(path: path, connection: connection)
        } else if pathOnly.hasPrefix("/api/image") {
            sendImage(path: path, connection: connection)
        } else if pathOnly == "/api/events" {
            handleSSEEvents(connection: connection)
        } else if pathOnly == "/api/ui-metrics/summary" {
            handleUiMetricsSummary(path: path, connection: connection)
        } else if pathOnly == "/api/ui-metrics/recent" {
            handleUiMetricsRecent(path: path, connection: connection)
        } else if pathOnly == "/api/ui-metrics/proc" {
            handleProcMetrics(connection: connection)
        } else if pathOnly == "/api/backup/status" {
            sendBackupStatus(path: path, connection: connection)
        } else if pathOnly == "/api/backup/snapshots" {
            sendBackupStatus(path: path, connection: connection)
        } else if pathOnly == "/api/sync/status" {
            sendSyncStatus(connection: connection)
        } else if pathOnly == "/api/oplogs" {
            sendOpLogs(path: path, connection: connection)
        } else if pathOnly.hasPrefix("/api/items/") && pathOnly.hasSuffix("/events") {
            sendItemEvents(path: path, connection: connection)
        } else if pathOnly.hasPrefix("/api/items/") && pathOnly.hasSuffix("/frequency") {
            sendItemFrequency(path: path, connection: connection)
        } else if pathOnly.hasPrefix("/api/items/") && pathOnly.hasSuffix("/evaluations") {
            sendItemEvaluations(path: path, connection: connection)
        } else if pathOnly.hasPrefix("/api/items/") && pathOnly.hasSuffix("/links") {
            sendItemLinks(path: path, connection: connection)
        } else if pathOnly == "/api/archive/view" {
            sendArchiveView(path: path, connection: connection)
        } else if pathOnly == "/api/archive/asset" {
            sendArchiveAsset(path: path, connection: connection)
        } else if pathOnly == "/api/archive/reader" {
            sendReaderBundle(path: path, connection: connection)
        } else if pathOnly == "/api/archive" || pathOnly.hasPrefix("/api/archive/") {
            sendArchiveStatus(path: path, connection: connection)
        } else if pathOnly.hasPrefix("/assets/") {
            sendStaticAsset(pathOnly: pathOnly, connection: connection)
        } else if pathOnly == "/trae" || pathOnly.hasPrefix("/trae/") {
            handleTraeProxy(path: path, connection: connection, method: "GET")
        } else {
            sendErrorResponse(connection: connection, status: 404, message: "Not Found")
        }
    }

    /// Loopback-only reverse proxy to the Trae DuckDB UI (default :9488).
    /// Browser stays on ClipVault HTTP; 9488 is an internal process port.
    static func traeBackendURL(from path: String) -> URL? {
        let port = Int(ProcessInfo.processInfo.environment["CLIPVAULT_TRAE_HTTP_PORT"] ?? "") ?? 9488
        let qMark = path.firstIndex(of: "?")
        let pathOnly = qMark.map { String(path[..<$0]) } ?? path
        let query = qMark.map { String(path[$0...]) } ?? ""
        var backend: String
        if pathOnly == "/trae" || pathOnly == "/trae/" {
            backend = "/"
        } else if pathOnly.hasPrefix("/trae/") {
            backend = String(pathOnly.dropFirst("/trae".count))
            if backend.isEmpty { backend = "/" }
        } else {
            return nil
        }
        return URL(string: "http://127.0.0.1:\(port)\(backend)\(query)")
    }

    private func handleTraeProxy(
        path: String,
        connection: HTTPByteSink,
        method: String = "GET",
        data: Data = Data(),
        headers: [String: String] = [:]
    ) {
        guard let url = Self.traeBackendURL(from: path) else {
            sendErrorResponse(connection: connection, status: 404, message: "Not Found")
            return
        }
        let pathOnly = path.split(separator: "?", maxSplits: 1).map(String.init).first ?? path
        if pathOnly == "/trae/api/stream" {
            TraeStreamPipe(client: connection, url: url).start()
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if method == "POST" || method == "PUT" || method == "PATCH" {
            req.httpBody = data
            req.setValue(headers["content-type"] ?? "application/json", forHTTPHeaderField: "Content-Type")
        }
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            if err != nil {
                let body = Data(#"{"error":"trae store unreachable"}"#.utf8)
                self.sendBinary(
                    status: 502,
                    reason: "Bad Gateway",
                    contentType: "application/json; charset=utf-8",
                    body: body,
                    connection: connection,
                    extraHeaders: [("Cache-Control", "no-store")]
                )
                return
            }
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 200
            let ctype = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            let reason = HTTPURLResponse.localizedString(forStatusCode: status)
            self.sendBinary(
                status: status,
                reason: reason.capitalized,
                contentType: ctype,
                body: data ?? Data(),
                connection: connection,
                extraHeaders: [("Cache-Control", "no-store")]
            )
        }.resume()
    }

    private func handleSSEEvents(connection: HTTPByteSink) {
        sseQueue.async { [weak self] in
            self?.attachSSELocked(connection)
        }
    }

    func broadcastSSE(event: String, id: String? = nil, extra: [String: Any] = [:]) {
        var obj: [String: Any] = ["type": event]
        if let id = id, !id.isEmpty { obj["id"] = id }
        for (k, v) in extra { obj[k] = v }
        guard let json = try? JSONSerialization.data(withJSONObject: obj),
              let jsonStr = String(data: json, encoding: .utf8) else { return }
        let payload = Data("data: \(jsonStr)\n\n".utf8)
        sseQueue.async { [weak self] in
            self?.publishSSELocked(payload)
        }
    }

    private func attachSSELocked(_ connection: HTTPByteSink) {
        pruneDeadSSELocked()
        if sseSessions.count >= 64 {
            if let oldest = sseSessions.values.first {
                dropSSELocked(oldest)
            }
        }
        let session = SSESession(connection)
        sseSessions[ObjectIdentifier(connection)] = session
        let id = ObjectIdentifier(connection)
        connection.watchPeerClose { [weak self] in
            self?.sseQueue.async {
                guard let session = self?.sseSessions[id] else { return }
                self?.dropSSELocked(session)
            }
        }
        let headers: [(String, String)] = [
            ("Content-Type", "text/event-stream; charset=utf-8"),
            ("Cache-Control", "no-cache, no-transform"),
            ("X-Accel-Buffering", "no"),
            ("Access-Control-Allow-Origin", "*")
        ]
        var hello = OriginWire.encodeResponse(status: 200, headers: headers, body: Data(), stream: true)
        hello.append(sseHelloBodyLocked())
        session.queue.append(hello)
        flushSSELocked(session)
        ensureSSEHeartbeatLocked()
    }

    private func publishSSELocked(_ payload: Data) {
        pruneDeadSSELocked()
        for session in sseSessions.values {
            enqueueSSELocked(session, payload)
        }
    }

    private func enqueueSSELocked(_ session: SSESession, _ payload: Data) {
        if session.dead { return }
        if session.resyncRequired { return }
        if session.queue.count >= Self.sseMaxBuffered {
            session.queue.removeAll(keepingCapacity: true)
            session.resyncRequired = true
            session.queue.append(Self.sseResyncFrame)
            flushSSELocked(session)
            return
        }
        session.queue.append(payload)
        flushSSELocked(session)
    }

    private func flushSSELocked(_ session: SSESession) {
        guard !session.inflight, !session.dead else { return }
        guard let next = session.queue.first else { return }
        session.queue.removeFirst()
        session.inflight = true
        session.connection.send(content: next) { [weak self, weak session] error in
            guard let self, let session else { return }
            self.sseQueue.async {
                session.inflight = false
                if error != nil {
                    self.dropSSELocked(session)
                    return
                }
                if session.resyncRequired && session.queue.isEmpty {
                    session.resyncRequired = false
                }
                self.flushSSELocked(session)
            }
        }
    }

    private func ensureSSEHeartbeatLocked() {
        if sseHeartbeat != nil { return }
        let timer = DispatchSource.makeTimerSource(queue: sseQueue)
        let interval = Self.sseHeartbeatSeconds
        timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        timer.setEventHandler { [weak self] in
            self?.sseHeartbeatTickLocked()
        }
        timer.resume()
        sseHeartbeat = timer
    }

    private func startProcSamplerLocked() {
        if procTimer != nil { return }
        let timer = DispatchSource.makeTimerSource(queue: sseQueue)
        timer.schedule(deadline: .now() + .milliseconds(400), repeating: .seconds(15))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.sseSessions.isEmpty {
                self.tickProcLocked()
            }
        }
        timer.resume()
        procTimer = timer
        tickProcLocked()
    }

    private func tickProcLocked() {
        UiMetrics.shared.drainHttpFront()
        let s = ProcMetrics.sample(sse: sseSessions.count)
        lastProc = s.asDict()
        UiMetrics.shared.emit(
            "proc_sample",
            ok: !s.strained,
            payload: [
                "fds": s.fds,
                "rss": s.rssMb,
                "unix": s.sockets,
                "sse": s.sse,
                "rlim": s.rlim,
            ]
        )
    }

    private func sseHelloBodyLocked() -> Data {
        tickProcLocked()
        var obj: [String: Any] = ["type": "connected"]
        for (k, v) in lastProc { obj[k] = v }
        guard let json = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: json, encoding: .utf8) else {
            return Data("retry: 3000\n\n: connected\n\ndata: {\"type\":\"connected\"}\n\n".utf8)
        }
        return Data("retry: 3000\n\n: connected\n\ndata: \(text)\n\n".utf8)
    }

    private func ssePingFrameLocked() -> Data {
        var obj: [String: Any] = ["type": "ping"]
        for (k, v) in lastProc { obj[k] = v }
        guard let json = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: json, encoding: .utf8) else {
            return Self.ssePingFrame
        }
        return Data(": ping\n\ndata: \(text)\n\n".utf8)
    }

    private func sseHeartbeatTickLocked() {
        pruneDeadSSELocked()
        if sseSessions.isEmpty {
            sseHeartbeat?.cancel()
            sseHeartbeat = nil
            return
        }
        tickProcLocked()
        let ping = ssePingFrameLocked()
        for session in sseSessions.values {
            if session.resyncRequired { continue }
            if session.queue.count >= Self.sseMaxBuffered { continue }
            session.queue.append(ping)
            flushSSELocked(session)
        }
    }

    private func pruneDeadSSELocked() {
        let stale = sseSessions.values.filter { session in
            session.dead || session.connection.isClosed
        }
        stale.forEach { dropSSELocked($0) }
    }

    private func dropSSELocked(_ session: SSESession) {
        session.dead = true
        session.queue.removeAll()
        sseSessions.removeValue(forKey: ObjectIdentifier(session.connection))
        session.connection.cancel()
        if sseSessions.isEmpty {
            sseHeartbeat?.cancel()
            sseHeartbeat = nil
        }
    }



    private func teardownSSELocked() {
        sseHeartbeat?.cancel()
        sseHeartbeat = nil
        for session in sseSessions.values {
            session.dead = true
            session.connection.cancel()
        }
        sseSessions.removeAll()
    }

    private func handlePostClip(data: Data, connection: HTTPByteSink) {
        guard let json = jsonBody(from: data) else {
            sendErrorResponse(connection: connection, status: 400, message: "Bad Request")
            return
        }
        let type = (json["type"] as? String)?.lowercased()
        if type == "image",
           let idStr = json["id"] as? String,
           let uuid = UUID(uuidString: idStr) {
            copyStoredImageToPasteboard(id: uuid, connection: connection)
            return
        }
        if let text = json["text"] as? String {
            // Force PLAIN TEXT only on system pasteboard.
            // clearContents + declareTypes([.string]) so public.html / RTF cannot linger;
            // monitor then classifies the capture as type=text (not html).
            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.declareTypes([.string], owner: nil)
                pb.setString(text, forType: .string)
            }
            self.database.appendOperationLog(
                action: "copy_ui",
                itemId: nil,
                contentHash: nil,
                detail: "plain_only len=\(text.count)",
                source: "web"
            )
            sendJSON(["status": "success", "copied": "text"], connection: connection)
            return
        }
        sendErrorResponse(connection: connection, status: 400, message: "Bad Request")
    }

    /// Put the stored CAS image on NSPasteboard (not OCR). Do not attach
    /// `public.utf8-plain-text` — many paste targets prefer text over image.
    private func copyStoredImageToPasteboard(id: UUID, connection: HTTPByteSink) {
        loadClipImageBytes(id: id) { [weak self] data in
            guard let self else { return }
            guard let data, data.count > 16 else {
                self.sendErrorResponse(connection: connection, status: 404, message: "Not Found")
                return
            }
            DispatchQueue.main.async {
                self.writeImageToPasteboard(data)
            }
            self.database.appendOperationLog(
                action: "copy_ui",
                itemId: id.uuidString,
                contentHash: nil,
                detail: "image_bytes=\(data.count)",
                source: "web"
            )
            self.sendJSON(["status": "success", "copied": "image"], connection: connection)
        }
    }

    /// Local CAS first, then the same hydrateBlob roots as archive (live/attach ∪ backup CAS).
    /// SQLite having a type=image row must not 404 the wall if any replica still has bytes.
    private func loadClipImageBytes(id: UUID? = nil, sha: String? = nil, completion: @escaping (Data?) -> Void) {
        if let raw = sha?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           ArchiveImageInliner.isAssetSHA(raw) {
            if let data = database.readBlobFile(hash: raw), data.count > 16 {
                completion(data)
                return
            }
            if sync?.hydrateBlob(raw) == true,
               let data = database.readBlobFile(hash: raw), data.count > 16 {
                completion(data)
                return
            }
            completion(nil)
            return
        }
        guard let id else { completion(nil); return }
        database.fetchImageData(id: id) { [weak self] data in
            if let data, data.count > 16 {
                completion(data)
                return
            }
            guard let self else { completion(nil); return }
            self.database.fetchItem(id: id) { item in
                self.loadClipImageBytes(sha: item?.contentHash, completion: completion)
            }
        }
    }

    private func writeImageToPasteboard(_ data: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let type: NSPasteboard.PasteboardType
        let payload: Data
        if ImageStoragePolicy.isPNG(data) {
            type = .png
            payload = data
        } else if ImageStoragePolicy.isJPEG(data) {
            type = NSPasteboard.PasteboardType("public.jpeg")
            payload = data
        } else if let png = convertToPNG(data) {
            type = .png
            payload = png
        } else {
            type = .tiff
            payload = data
        }
        pb.setData(payload, forType: type)
    }

    private func handleDeleteClip(path: String, connection: HTTPByteSink) {
        guard let comps = URLComponents(string: "http://localhost\(path)"),
              let idValue = comps.queryItems?.first(where: { $0.name == "id" })?.value,
              let uuid = UUID(uuidString: idValue) else {
            sendErrorResponse(connection: connection, status: 400, message: "Bad Request")
            return
        }
        database.deleteItem(id: uuid) { [weak self] success in
            guard let self = self else { return }
            if success {
                // Soft-delete only — do not tombstone peers (row still exists for TTL).
                self.broadcastSSE(event: "clip_deleted", id: uuid.uuidString)
                self.sendJSON(["status": "deleted", "soft": true], connection: connection)
            } else {
                self.sendErrorResponse(connection: connection, status: 500, message: "Failed to delete")
            }
        }
    }

    
    private func handleRestoreClip(data: Data, connection: HTTPByteSink) {
        guard let json = jsonBody(from: data),
              let idValue = json["id"] as? String,
              let uuid = UUID(uuidString: idValue) else {
            sendErrorResponse(connection: connection, status: 400, message: "Bad Request")
            return
        }
        database.restoreItem(id: uuid) { [weak self] ok in
            guard let self = self else { return }
            if ok {
                self.broadcastSSE(event: "clip_restored", id: uuid.uuidString)
                self.sendJSON(["status": "restored"], connection: connection)
            } else {
                self.sendErrorResponse(connection: connection, status: 404, message: "Not in trash")
            }
        }
    }

    private func sendOpLogs(path: String, connection: HTTPByteSink) {
        let comps = URLComponents(string: "http://localhost" + path)
        let limit = comps?.queryItems?.first(where: { $0.name == "limit" }).flatMap { Int($0.value ?? "") } ?? 100
        database.fetchOperationLogs(limit: limit) { [weak self] rows in
            guard let self = self else { return }
            self.sendJSON(["items": rows, "count": rows.count], connection: connection)
        }
    }

    private func sendItemEvents(path: String, connection: HTTPByteSink) {
        let pathOnly = path.split(separator: "?").map(String.init).first ?? path
        let parts = pathOnly.split(separator: "/").map(String.init)
        // api items {uuid} events
        guard parts.count >= 4,
              let uuid = UUID(uuidString: parts[2]) else {
            sendErrorResponse(connection: connection, status: 400, message: "Bad Request")
            return
        }
        let comps = URLComponents(string: "http://localhost" + path)
        let limit = comps?.queryItems?.first(where: { $0.name == "limit" }).flatMap { Int($0.value ?? "") } ?? 50
        database.fetchItemEvents(itemId: uuid, limit: limit) { [weak self] rows in
            guard let self = self else { return }
            self.sendJSON(["itemId": uuid.uuidString, "events": rows, "count": rows.count], connection: connection)
        }
    }

    private func sendItemFrequency(path: String, connection: HTTPByteSink) {
        let comps = URLComponents(string: "http://localhost" + path)
        if let hash = comps?.queryItems?.first(where: { $0.name == "hash" })?.value, !hash.isEmpty {
            database.contentFrequency(contentHash: hash) { [weak self] freq in
                self?.sendJSON(freq, connection: connection)
            }
            return
        }
        sendErrorResponse(connection: connection, status: 400, message: "hash query required")
    }

    private func sendSyncStatus(connection: HTTPByteSink) {
        guard let sync = sync else {
            sendJSON(["enabled": false, "error": "sync not configured"], connection: connection)
            return
        }
        sync.statusSnapshot { [weak self] st in
            guard let self = self else { return }
            let peers: [[String: Any]] = st.peers.map {
                [
                    "host": $0.host,
                    "remoteSeq": $0.remoteSeq,
                    "appliedSeq": $0.appliedSeq,
                    "lag": $0.lag
                ]
            }
            let dict: [String: Any] = [
                "enabled": st.enabled,
                "hostId": st.hostId,
                "localSeq": st.localSeq,
                "outboxPending": st.outboxPending,
                "cloudDocsAvailable": st.cloudDocsAvailable,
                "syncRootPath": st.syncRootPath as Any,
                "trxPath": st.trxPath as Any,
                "lastPushAt": st.lastPushAt as Any,
                "lastPullAt": st.lastPullAt as Any,
                "lastPhase": st.lastPhase as Any,
                "lastError": st.lastError as Any,
                "inProgress": st.inProgress,
                "peers": peers,
                "pollIntervalSeconds": st.pollIntervalSeconds,
                "scheme": st.scheme,
                "policy": st.policy
            ]
            self.sendJSON(dict, connection: connection)
        }
    }

    private func handleSyncNow(connection: HTTPByteSink) {
        guard let sync = sync else {
            sendErrorResponse(connection: connection, status: 503, message: "sync not configured")
            return
        }
        sync.runNow { [weak self] ok, msg in
            guard let self = self else { return }
            self.sendJSON(["ok": ok, "message": msg], connection: connection)
        }
    }

    private func handleSyncConfig(data: Data, connection: HTTPByteSink) {
        guard let sync = sync else {
            sendErrorResponse(connection: connection, status: 503, message: "sync not configured")
            return
        }
        // Body may include headers; take last JSON object if present.
        let raw = String(data: data, encoding: .utf8) ?? ""
        var enabled: Bool?
        if let brace = raw.range(of: "{", options: .backwards),
           let jsonData = raw[brace.lowerBound...].data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let e = obj["enabled"] as? Bool {
            enabled = e
        }
        guard let enabled = enabled else {
            sendErrorResponse(connection: connection, status: 400, message: "expected {\"enabled\":bool}")
            return
        }
        sync.setEnabled(enabled) { [weak self] _ in
            self?.sendSyncStatus(connection: connection)
        }
    }

    private func sendJSON(_ object: [String: Any], connection: HTTPByteSink) {
        guard let body = try? JSONSerialization.data(withJSONObject: object) else {
            sendErrorResponse(connection: connection, status: 500, message: "JSON encode failed")
            return
        }
        sendBinary(
            status: 200,
            reason: "OK",
            contentType: "application/json; charset=utf-8",
            body: body,
            connection: connection,
            extraHeaders: [("Cache-Control", "no-store")]
        )
    }
    
    /// Serve files from ./web/assets (logo, favicon, etc.)
    private func sendStaticAsset(pathOnly: String, connection: HTTPByteSink) {
        // pathOnly like /assets/keepsake-logo.jpg — prevent path traversal
        let name = pathOnly
            .replacingOccurrences(of: "/assets/", with: "")
            .replacingOccurrences(of: "..", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !name.isEmpty, !name.contains("..") else {
            sendErrorResponse(connection: connection, status: 404, message: "Not Found")
            return
        }
        guard let webRoot = projectWebDirectory() else {
            sendErrorResponse(connection: connection, status: 404, message: "Not Found")
            return
        }
        let filePath = webRoot + "/assets/" + name
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)), !data.isEmpty else {
            sendErrorResponse(connection: connection, status: 404, message: "Not Found")
            return
        }
        let ext = (name as NSString).pathExtension.lowercased()
        let ctype: String
        switch ext {
        case "jpg", "jpeg": ctype = "image/jpeg"
        case "png": ctype = "image/png"
        case "webp": ctype = "image/webp"
        case "svg": ctype = "image/svg+xml"
        case "ico": ctype = "image/x-icon"
        case "js": ctype = "text/javascript; charset=utf-8"
        case "css": ctype = "text/css; charset=utf-8"
        case "mjs": ctype = "text/javascript; charset=utf-8"
        case "woff2": ctype = "font/woff2"
        case "woff": ctype = "font/woff"
        case "ttf": ctype = "font/ttf"
        default: ctype = "application/octet-stream"
        }
        let cache = (ext == "css" || ext == "js" || ext == "mjs")
            ? "public, max-age=60, must-revalidate"
            : "public, max-age=86400"
        sendBinary(
            status: 200,
            reason: "OK",
            contentType: ctype,
            body: data,
            connection: connection,
            extraHeaders: [("Cache-Control", cache)]
        )
    }

    private func sendWebFile(_ name: String, connection: HTTPByteSink) {
        guard let webRoot = projectWebDirectory() else {
            sendErrorResponse(connection: connection, status: 404, message: "Not Found")
            return
        }
        let path = webRoot + "/" + name
        guard let html = try? String(contentsOfFile: path, encoding: .utf8) else {
            sendErrorResponse(connection: connection, status: 404, message: "Not Found")
            return
        }
        sendBinary(
            status: 200,
            reason: "OK",
            contentType: "text/html; charset=utf-8",
            body: Data(html.utf8),
            connection: connection,
            extraHeaders: [
                ("Cache-Control", "no-store, no-cache, must-revalidate"),
                ("Pragma", "no-cache"),
            ]
        )
    }

    private func sendHTMLResponse(connection: HTTPByteSink) {
        var html = WebServer.indexHTML
        if let webRoot = projectWebDirectory() {
            let webPath = webRoot + "/index.html"
            if let customHTML = try? String(contentsOfFile: webPath, encoding: .utf8) {
                html = customHTML
            }
        }
        // Inject server display zone so clients never depend on browser TZ alone.
        let tzBoot = "<script>window.__CLIP_TZ=\(jsonStringLiteral(ClipTimeFormat.timeZoneId));window.__CLIP_TZ_OFFSET_MIN=\(ClipTimeFormat.displayTimeZone.secondsFromGMT() / 60);</script>\n"
        if let range = html.range(of: "<head>") {
            html.replaceSubrange(range, with: "<head>\n" + tzBoot)
        } else {
            html = tzBoot + html
        }
        let body = Data(html.utf8)
        sendBinary(
            status: 200,
            reason: "OK",
            contentType: "text/html; charset=utf-8",
            body: body,
            connection: connection,
            extraHeaders: [
                ("Cache-Control", "no-store, no-cache, must-revalidate"),
                ("Pragma", "no-cache"),
            ]
        )
    }

    private func jsonStringLiteral(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static var indexHTML: String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>ClipFlow - Clipboard History</title>
            <style>
                \(indexCSS)
            </style>
        </head>
        <body>
            <div class="container">
                <header class="header">
                    <h1>
                        <span>🦞</span> ClipFlow
                    </h1>
                    <div class="search-container">
                        <input type="text" id="searchInput" placeholder="Search history..." autocomplete="off">
                    </div>
                </header>
                
                <main id="itemsGrid" class="grid">
                    <div class="empty-state" style="grid-column: 1/-1; text-align: center; padding: 40px; color: var(--text-secondary);">
                        <p>Loading...</p>
                    </div>
                </main>
            </div>
            
            <div id="toast" class="toast">Copied to clipboard!</div>

            <script>
                \(indexJS)
            </script>
        </body>
        </html>
        """
    }

    private static var indexCSS: String {
        """
        :root {
            --bg-color: #f5f5f7;
            --card-bg: #ffffff;
            --text-primary: #1d1d1f;
            --text-secondary: #86868b;
            --accent: #007aff;
            --border: #d2d2d7;
            --shadow: 0 2px 8px rgba(0,0,0,0.04);
            --shadow-hover: 0 8px 16px rgba(0,0,0,0.08);
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --bg-color: #1c1c1e;
                --card-bg: #2c2c2e;
                --text-primary: #f5f5f7;
                --text-secondary: #aeaeb2;
                --border: #3a3a3c;
                --shadow: 0 2px 8px rgba(0,0,0,0.2);
            }
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
            background-color: var(--bg-color);
            color: var(--text-primary);
            padding: 24px;
            transition: background-color 0.3s;
        }
        .container { max-width: 900px; margin: 0 auto; }
        .header {
            display: flex; justify-content: space-between; align-items: center;
            margin-bottom: 32px; padding: 0 8px;
        }
        .header h1 { font-size: 24px; font-weight: 700; display: flex; align-items: center; gap: 8px; }
        .search-container { position: relative; width: 300px; }
        .search-container input {
            width: 100%; padding: 10px 16px; border-radius: 10px; border: 1px solid var(--border);
            background: var(--card-bg); color: var(--text-primary); font-size: 14px;
            transition: all 0.2s;
        }
        .search-container input:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 0 3px rgba(0,122,255,0.1); }
        
        .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 20px; }
        
        .card {
            background: var(--card-bg); border-radius: 16px; overflow: hidden;
            box-shadow: var(--shadow); border: 1px solid var(--border);
            transition: transform 0.2s, box-shadow 0.2s;
            display: flex; flex-direction: column;
            position: relative;
        }
        .card:hover { transform: translateY(-2px); box-shadow: var(--shadow-hover); }
        
        .card-header {
            padding: 12px 16px; display: flex; justify-content: space-between; align-items: center;
            border-bottom: 1px solid var(--border); background: rgba(0,0,0,0.02);
        }
        .badge {
            font-size: 11px; font-weight: 600; text-transform: uppercase; padding: 4px 8px; border-radius: 6px;
            background: #e5e5ea; color: #1d1d1f;
        }
        .time { font-size: 12px; color: var(--text-secondary); }
        
        .card-body { padding: 16px; flex: 1; min-height: 100px; max-height: 300px; overflow-y: auto; }
        .content-text { font-size: 14px; line-height: 1.5; white-space: pre-wrap; word-break: break-word; }
        .content-html { padding: 8px; background: #fff; border-radius: 8px; color: #000; overflow: hidden; }
        .content-img { width: 100%; height: auto; border-radius: 8px; display: block; }
        
        .card-footer {
            padding: 12px 16px; border-top: 1px solid var(--border);
            display: flex; justify-content: space-between; align-items: center;
            background: rgba(0,0,0,0.02);
        }
        .source { font-size: 12px; color: var(--text-secondary); display: flex; align-items: center; gap: 4px; }
        .actions button {
            background: transparent; border: 1px solid var(--border); border-radius: 6px;
            padding: 6px 12px; font-size: 12px; font-weight: 500; cursor: pointer;
            color: var(--text-primary); transition: all 0.2s;
        }
        .actions button:hover { background: var(--accent); color: white; border-color: var(--accent); }
        
        .toast {
            position: fixed; bottom: 24px; left: 50%; transform: translateX(-50%);
            background: rgba(0,0,0,0.8); color: white; padding: 10px 20px; border-radius: 20px;
            font-size: 14px; opacity: 0; pointer-events: none; transition: opacity 0.3s;
        }
        .toast.show { opacity: 1; }
        """
    }

    private static var indexJS: String {
        """
        let allItems = [];
        
        async function loadItems() {
            try {
                const response = await fetch('/api/items');
                if (!response.ok) throw new Error('Network response was not ok');
                allItems = await response.json();
                renderItems(allItems);
            } catch (error) {
                console.error('Failed to load items:', error);
                document.getElementById('itemsGrid').innerHTML = 
                    `<div style="text-align:center; padding:40px; color:var(--text-secondary); grid-column:1/-1;">
                        Failed to load history. Please refresh.
                    </div>`;
            }
        }
        
        function renderItems(items) {
            const container = document.getElementById('itemsGrid');
            if (!items || items.length === 0) {
                container.innerHTML = `
                    <div style="text-align:center; padding:40px; color:var(--text-secondary); grid-column:1/-1;">
                        <div style="font-size:48px; margin-bottom:16px;">📭</div>
                        <p>No clipboard items found</p>
                    </div>`;
                return;
            }
            
            container.innerHTML = items.map(item => {
                const d = new Date(item.timestamp * 1000);
                const p = n => String(n).padStart(2, '0');
                const time = d.getFullYear() + '/' + p(d.getMonth()+1) + '/' + p(d.getDate())
                  + ' ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
                let contentHtml = '';
                
                // 优先展示图片
                if (item.type === 'image') {
                    contentHtml = `<img class="content-img" src="/api/image?id=${item.id}" loading="lazy" alt="Clipboard Image">`;
                    // 如果有 OCR 文本，也附带展示
                    if (item.preview && item.preview !== 'Image') {
                        contentHtml += `<div class="content-text" style="margin-top:8px; opacity:0.8; font-size:12px;">OCR: ${escapeHtml(item.preview)}</div>`;
                    }
                } 
                // 其次展示 HTML (如果安全)
                else if (item.htmlContent) {
                     // 简单沙箱 iframe 防止样式污染，或者直接 div (信任本地网络)
                     // 这里为了演示效果，直接放入 div，但要注意 XSS 风险（但在局域网自用工具中风险可控）
                     // 更好的做法是 strip scripts
                     contentHtml = `<div class="content-html">${item.htmlContent}</div>`;
                }
                // 最后展示纯文本
                else {
                    const text = item.textContent || item.preview || '';
                    contentHtml = `<div class="content-text">${escapeHtml(text)}</div>`;
                }
                
                // 准备拷贝的数据
                // 为了简化，拷贝按钮主要拷贝文本内容
                const copyValue = escapeAttribute(item.textContent || item.preview || '');

                return `
                <article class="card">
                    <div class="card-header">
                        <span class="badge">${item.type}</span>
                        <span class="time">${time}</span>
                    </div>
                    <div class="card-body">
                        ${contentHtml}
                    </div>
                    <div class="card-footer">
                        <div class="source">
                            ${item.sourceApp ? `<span>📱 ${escapeHtml(item.sourceApp)}</span>` : ''}
                        </div>
                        <div class="actions">
                            <button onclick="copyText(this)" data-text="${copyValue}">Copy</button>
                        </div>
                    </div>
                </article>
                `;
            }).join('');
        }
        
        function escapeHtml(text) {
            if (!text) return '';
            return text
                .replace(/&/g, "&amp;")
                .replace(/</g, "&lt;")
                .replace(/>/g, "&gt;")
                .replace(/"/g, "&quot;")
                .replace(/'/g, "&#039;");
        }
        
        function escapeAttribute(text) {
            if (!text) return '';
            return text.replace(/"/g, '&quot;');
        }
        
        window.copyText = async (btn) => {
            const text = btn.getAttribute('data-text');
            if (!text) return;
            
            try {
                await navigator.clipboard.writeText(text);
                showToast("Copied to clipboard!");
                
                // 按钮反馈
                const originalText = btn.textContent;
                btn.textContent = "Copied!";
                btn.style.background = "var(--text-primary)";
                btn.style.color = "var(--bg-color)";
                setTimeout(() => {
                    btn.textContent = originalText;
                    btn.style.background = "";
                    btn.style.color = "";
                }, 2000);
            } catch (err) {
                console.error('Failed to copy:', err);
                showToast("Failed to copy (browser restriction?)");
            }
        };
        
        function showToast(msg) {
            const toast = document.getElementById('toast');
            toast.textContent = msg;
            toast.classList.add('show');
            setTimeout(() => toast.classList.remove('show'), 3000);
        }
        
        // 搜索过滤
        const searchInput = document.getElementById('searchInput');
        searchInput.addEventListener('input', (e) => {
            const query = e.target.value.toLowerCase();
            if (!query) {
                renderItems(allItems);
                return;
            }
            const filtered = allItems.filter(item => {
                const text = (item.textContent || item.preview || '').toLowerCase();
                const src = (item.sourceApp || '').toLowerCase();
                return text.includes(query) || src.includes(query);
            });
            renderItems(filtered);
        });
        
        // 初始加载与轮询
        loadItems();
        setInterval(loadItems, 5000);
        """
    }
    
    private func itemToJSON(_ item: ClipboardItem, includeArchiveHTML: Bool = false, headOnly: Bool = false) -> [String: Any] {
        if headOnly {
            var head: [String: Any] = [
                "id": item.id.uuidString,
                "timestamp": item.timestamp.timeIntervalSince1970,
                "type": item.type.rawValue,
                "linkCount": item.linkCount,
                "archived": item.archiveHtmlSha != nil,
                "inTrash": item.deletedAt != nil,
            ]
            if let pin = item.pinnedAt {
                head["pinned"] = true
                head["pinnedAt"] = pin.timeIntervalSince1970
            } else {
                head["pinned"] = false
                head["pinnedAt"] = NSNull()
            }
            if item.type == .note { head["isCompose"] = true }
            return head
        }
        let ts = item.timestamp.timeIntervalSince1970
        let first = (item.firstSeenAt ?? item.timestamp).timeIntervalSince1970
        var dict: [String: Any] = [
            "id": item.id.uuidString,
            "timestamp": ts,
            // Preformatted wall clock — UI must prefer this over client TZ math.
            "timeLocal": ClipTimeFormat.displayWall(unix: ts),
            "timeZone": ClipTimeFormat.timeZoneId,
            "type": item.type.rawValue,
            "preview": item.preview(),
            "sourceApp": item.sourceApp ?? "",
            "copyCount": item.copyCount,
            "contentHash": item.contentHash,
            "firstSeenAt": first,
            "firstSeenLocal": ClipTimeFormat.displayWall(unix: first),
        ]
        if let deleted = item.deletedAt {
            let d = deleted.timeIntervalSince1970
            dict["deletedAt"] = d
            dict["deletedAtLocal"] = ClipTimeFormat.displayWall(unix: d)
            dict["inTrash"] = true
        } else {
            dict["inTrash"] = false
        }
        if let text = item.textContent { dict["textContent"] = text }
        // URL archive is an overlay — never dump article HTML into clip JSON.
        // View loads GET /api/archive/view (real document). Cards only get a flag.
        var archived = item.archiveHtmlSha != nil
        let shouldLoadArchiveMeta = archived || item.type == .url
        if shouldLoadArchiveMeta,
           let metaStr = database.webArchiveMetaJSON(id: item.id),
           let metaData = metaStr.data(using: .utf8),
           let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] {
            archived = true
            dict["archive"] = meta
        }
        if item.type == .url, (item.htmlContent?.count ?? 0) > 40 {
            archived = true
        }
        dict["archived"] = archived
        if item.type != .url, let html = item.htmlContent, !archived {
            dict["htmlContent"] = html
        } else if !archived, item.type == .html || item.type == .rtf, item.htmlContent == nil {
            // List SQL omitted a large clipboard HTML body; wall hydrates via GET ?id=.
            dict["htmlOmitted"] = true
        }
        _ = includeArchiveHTML
        if let ocr = item.ocrText { dict["ocrText"] = ocr }
        if let urls = item.fileURLs, !urls.isEmpty {
            dict["filePaths"] = urls.map { $0.path }
            dict["fileNames"] = urls.map { $0.lastPathComponent }
        }
        // User judgment projection (capture payload remains immutable).
        if let note = item.userNote { dict["userNote"] = note }
        if let stage = item.userStage { dict["userStage"] = stage }
        if let rating = item.userRating { dict["userRating"] = rating }
        if let uat = item.userContextUpdatedAt {
            let u = uat.timeIntervalSince1970
            dict["userContextUpdatedAt"] = u
            dict["userContextUpdatedAtLocal"] = ClipTimeFormat.displayWall(unix: u)
        }
        dict["hasUserContext"] = (item.userNote != nil)
            || (item.userStage != nil)
            || (item.userRating != nil)
        if let pin = item.pinnedAt {
            dict["pinned"] = true
            dict["pinnedAt"] = pin.timeIntervalSince1970
        } else {
            dict["pinned"] = false
            dict["pinnedAt"] = NSNull()
        }
        dict["linkCount"] = item.linkCount
        dict["shared"] = item.shared
        // Thumb URL for image types — client never loads full blob in feed
        if item.type == .image {
            dict["thumbUrl"] = "/api/image?id=\(item.id.uuidString)&size=thumb&cv=3"
            dict["fullUrl"] = "/api/image?id=\(item.id.uuidString)&size=full"
        }
        if item.type == .note {
            dict["isCompose"] = true
            if let ref = ComposeNotes.refId(from: item.url) {
                dict["composeRefId"] = ref
            }
        }
        return dict
    }

    /// POST /api/ui-metrics  { events:[{name, ts?, dur_ms?, ok?, payload?}], session? }
    /// Local diagnostics only. Never synced. Payload must not contain note content.
    private func handleUiMetricsIngest(data: Data, connection: HTTPByteSink) {
        guard let obj = jsonBody(from: data),
              let events = obj["events"] as? [[String: Any]] else {
            sendJSON(["ok": false, "message": "expected {events:[]}"], connection: connection)
            return
        }
        let session = (obj["session"] as? String) ?? "anon"
        let r = UiMetrics.shared.ingest(events: events, defaultSession: session)
        if !r.ok {
            sendJSON(["ok": false, "message": r.message ?? "rejected"], connection: connection)
            return
        }
        sendJSON(["ok": true, "accepted": r.accepted], connection: connection)
    }

    /// GET /api/ui-metrics/summary?from=&to=  unix ms. Default last 24h.
    private func handleUiMetricsSummary(path: String, connection: HTTPByteSink) {
        func ms(_ name: String) -> Int64? {
            guard let s = Self.formQueryValue(path: path, name: name), let n = Int64(s) else { return nil }
            return n
        }
        sendJSON(UiMetrics.shared.summary(fromMs: ms("from"), toMs: ms("to")), connection: connection)
    }

    /// GET /api/ui-metrics/proc  live fd/rss/sse snapshot. No content.
    private func handleProcMetrics(connection: HTTPByteSink) {
        sseQueue.async { [weak self] in
            guard let self else { return }
            let s = ProcMetrics.sample(sse: self.sseSessions.count)
            self.lastProc = s.asDict()
            self.sendJSON(s.asJSON(ok: true), connection: connection)
        }
    }

    /// GET /api/ui-metrics/recent?name=&limit=&from=&to=  last N local rows. No content.
    private func handleUiMetricsRecent(path: String, connection: HTTPByteSink) {
        func ms(_ name: String) -> Int64? {
            guard let s = Self.formQueryValue(path: path, name: name), let n = Int64(s) else { return nil }
            return n
        }
        let name = Self.formQueryValue(path: path, name: "name")
        let limit = Int(Self.formQueryValue(path: path, name: "limit") ?? "") ?? 80
        sendJSON(
            UiMetrics.shared.recent(name: name, limit: limit, fromMs: ms("from"), toMs: ms("to")),
            connection: connection
        )
    }

    /// POST /api/compose  { id?, title?, body, refId? }
    private func handleComposeSave(data: Data, connection: HTTPByteSink) {
        guard let obj = jsonBody(from: data) else {
            sendJSON(["ok": false, "message": "expected {body}"], connection: connection)
            return
        }
        let body = (obj["body"] as? String) ?? ""
        let title = obj["title"] as? String
        let refId = obj["refId"] as? String
        let parentHash = obj["parentHash"] as? String
        let id = (obj["id"] as? String).flatMap { UUID(uuidString: $0) }
        database.saveComposeNote(
            id: id,
            title: title,
            body: body,
            refId: refId,
            parentHash: parentHash,
            source: "web"
        ) { [weak self] result, err in
            guard let self else { return }
            guard let result else {
                self.sendJSON(["ok": false, "message": err ?? "保存失败"], connection: connection)
                return
            }
            CloudDocsSyncService.shared?.recordLocalCompose(item: result.item, parentHash: result.parentHash)
            self.broadcastSSE(event: "compose_saved", id: result.item.id.uuidString)
            self.sendJSON([
                "ok": true,
                "item": self.itemToJSON(result.item),
                "conflict": result.conflict,
                "merged": result.merged,
            ], connection: connection)
        }
    }

    /// POST /api/compose/image  { data: base64, mime? }
    private func handleComposeImage(data: Data, connection: HTTPByteSink) {
        guard let obj = jsonBody(from: data),
              var raw = obj["data"] as? String else {
            sendJSON(["ok": false, "message": "expected {data}"], connection: connection)
            return
        }
        if let comma = raw.firstIndex(of: ","), raw.lowercased().contains("base64") {
            raw = String(raw[raw.index(after: comma)...])
        }
        raw = raw.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        guard let bytes = Data(base64Encoded: raw), !bytes.isEmpty, bytes.count <= 6_000_000 else {
            sendJSON(["ok": false, "message": "图片太大或无法解码"], connection: connection)
            return
        }
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard database.writeBlobFile(hash: sha, data: bytes) else {
            sendJSON(["ok": false, "message": "写入失败"], connection: connection)
            return
        }
        sendJSON(["ok": true, "sha": sha, "url": "/api/image?sha=\(sha)"], connection: connection)
    }

    /// POST /api/archive  { url, itemId? }
    /// Manual web archive — WKWebView + Readability. Never auto.
    private func handleArchivePost(data: Data, connection: HTTPByteSink) {
        guard let archive else {
            sendJSON(["ok": false, "message": "归档服务未启动"], connection: connection)
            return
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard let brace = raw.range(of: "{"),
              let jsonData = raw[brace.lowerBound...].data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let urlStr = obj["url"] as? String,
              let url = URL(string: urlStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            sendJSON(["ok": false, "message": "expected {url, itemId?}"], connection: connection)
            return
        }
        var itemId: UUID?
        if let s = obj["itemId"] as? String { itemId = UUID(uuidString: s) }
        let (job, reason) = archive.enqueue(url: url, itemId: itemId)
        if let job {
            sendJSON(["ok": true, "job": job.json()], connection: connection)
        } else {
            sendJSON(["ok": false, "message": reason ?? "无法归档"], connection: connection)
        }
    }

    /// DELETE /api/archive?id=  — drop archive overlay, keep URL clip.
    private func handleArchiveClear(path: String, connection: HTTPByteSink) {
        guard let comps = URLComponents(string: "http://localhost\(path)"),
              let idStr = comps.queryItems?.first(where: { $0.name == "id" })?.value,
              let uuid = UUID(uuidString: idStr) else {
            sendJSON(["ok": false, "message": "expected ?id="], connection: connection)
            return
        }
        database.clearWebArchive(id: uuid) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.broadcastSSE(event: "archive_cleared", id: uuid.uuidString)
            }
            self.sendJSON(["ok": ok], connection: connection)
        }
    }

    /// GET /api/archive/view?id=&embed=1
    /// Full HTML document so the browser engine lays out `<pre>`/`<br>`/`&nbsp;`.
    /// Sheet iframe uses embed=1 (no chrome). New-tab uses the same document.
    private func sendArchiveView(path: String, connection: HTTPByteSink) {
        guard let comps = URLComponents(string: "http://localhost\(path)"),
              let idStr = comps.queryItems?.first(where: { $0.name == "id" })?.value,
              let uuid = UUID(uuidString: idStr) else {
            sendErrorResponse(connection: connection, status: 400, message: "expected ?id=")
            return
        }
        let embed = comps.queryItems?.contains(where: { $0.name == "embed" && ($0.value == "1" || $0.value == "true") }) == true
        let html = database.fetchArchiveHTML(id: uuid)
        let metaStr = database.webArchiveMetaJSON(id: uuid)
        database.fetchItem(id: uuid) { [weak self] item in
            guard let self else { return }
            guard let html, html.count > 40 else {
                self.sendErrorResponse(connection: connection, status: 404, message: "no archive")
                return
            }
            var title = "归档"
            var source = item?.textContent ?? ""
            if let metaData = metaStr?.data(using: .utf8),
               let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] {
                if let t = meta["title"] as? String, !t.isEmpty { title = t }
                if let u = meta["sourceUrl"] as? String, !u.isEmpty { source = u }
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let body = ArchiveImageInliner.flattenPictures(self.promoteLazyImages(html))
                // Do not block View on CDN fetches. Medium images go through SOCKS;
                // URLSession.shared (direct) used to hang this GET until the iframe looked empty.
                let doc = self.buildArchiveViewDocument(
                    title: title,
                    source: source,
                    bodyHTML: self.decorateArchiveMedia(body),
                    archiveId: uuid.uuidString,
                    embed: embed
                )
                self.sendBinary(
                    status: 200,
                    reason: "OK",
                    contentType: "text/html; charset=utf-8",
                    body: Data(doc.utf8),
                    connection: connection,
                    extraHeaders: [
                        ("Cache-Control", "private, no-store"),
                        ("Content-Security-Policy", "default-src 'none'; img-src 'self' data: blob:; media-src * blob:; style-src 'self' 'unsafe-inline'; font-src 'self'; script-src 'self'; connect-src 'self'; frame-src https://www.youtube-nocookie.com https://www.youtube.com https://player.vimeo.com"),
                        ("X-Content-Type-Options", "nosniff"),
                    ]
                )
                if ArchiveImageInliner.containsRemoteImages(body) {
                    self.inlineArchiveImagesInBackground(id: uuid, html: body, source: source, title: title, metaStr: metaStr)
                }
            }
        }
    }

    /// Fetch publisher images via SOCKS (same as WK archive) and rewrite CAS. Never block View.
    private func inlineArchiveImagesInBackground(
        id: UUID,
        html: String,
        source: String,
        title: String,
        metaStr: String?
    ) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let local = ArchiveImageInliner.embed(
                html: html,
                pageURL: URL(string: source),
                writeBlob: { hash, data in self.database.writeBlobFile(hash: hash, data: data) }
            )
            guard local != html else { return }
            var metaObj: [String: Any] = [:]
            if let metaStr, let data = metaStr.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                metaObj = parsed
            }
            metaObj["bytes"] = local.utf8.count
            metaObj["imagesOffline"] = true
            let sha = SHA256.hash(data: Data(local.utf8)).map { String(format: "%02x", $0) }.joined()
            let keys = ArchiveBlobClosure.stamp(&metaObj, root: sha, html: local)
            let newMeta = ArchiveBlobClosure.encodeMeta(metaObj)
            self.database.applyWebArchive(
                id: id,
                html: local,
                textSnippet: "",
                title: title,
                metaJSON: newMeta
            ) { ok in
                if ok {
                    CloudDocsSyncService.shared?.recordLocalArchive(
                        itemId: id,
                        htmlSHA: sha,
                        metaJSON: newMeta,
                        blobKeys: keys
                    )
                }
            }
        }
    }

    /// GET /api/archive/asset?sha=  — CAS image for an archive view. Never a publisher CDN.
    private func sendArchiveAsset(path: String, connection: HTTPByteSink) {
        guard let comps = URLComponents(string: "http://localhost\(path)"),
              let sha = comps.queryItems?.first(where: { $0.name == "sha" })?.value?.lowercased(),
              ArchiveImageInliner.isAssetSHA(sha) else {
            sendErrorResponse(connection: connection, status: 400, message: "expected ?sha=")
            return
        }
        var data = database.readBlobFile(hash: sha)
        if data == nil || (data?.count ?? 0) <= 16 {
            if sync?.hydrateBlob(sha) == true {
                data = database.readBlobFile(hash: sha)
            }
        }
        guard let data, data.count > 16 else {
            sendErrorResponse(connection: connection, status: 404, message: "not an archive asset")
            return
        }
        sendBinary(
            status: 200,
            reason: "OK",
            contentType: ArchiveImageInliner.mimeType(for: data),
            body: data,
            connection: connection,
            extraHeaders: [
                ("Cache-Control", "private, max-age=31536000, immutable"),
                ("X-Content-Type-Options", "nosniff"),
            ]
        )
    }

    private func buildArchiveViewDocument(
        title: String,
        source: String,
        bodyHTML: String,
        archiveId: String,
        embed: Bool
    ) -> String {
        let safeTitle = htmlEscapeText(title)
        let safeSource = htmlEscapeText(source)
        let safeId = htmlEscapeText(archiveId)
        let bar = embed ? "" : """
          <header class="cv-bar">
            <h1>\(safeTitle)</h1>
            <p>\(safeSource)</p>
          </header>
        """
        return """
        <!DOCTYPE html>
        <html lang="zh-CN" data-archive-id="\(safeId)">
        <head>
          <meta charset="utf-8"/>
          <meta name="viewport" content="width=device-width,initial-scale=1"/>
          <title>\(safeTitle)</title>
          <meta name="color-scheme" content="light"/>
          <link rel="stylesheet" href="/assets/archive-view.css?v=20260905a"/>
          <script src="/assets/archive-reader.js?v=20260827f" defer></script>
        </head>
        <body>
        \(bar)
          <main class="cv-article">
        \(bodyHTML)
          </main>
        </body>
        </html>
        """
    }

    private func htmlEscapeText(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func htmlAttr(_ tag: String, _ name: String) -> String? {
        let pat = #"(?i)\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*"([^"]*)""#
        guard let re = try? NSRegularExpression(pattern: pat) else { return nil }
        let ns = tag as NSString
        guard let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private func isPlaceholderImageSrc(_ src: String) -> Bool {
        let s = src.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return true }
        if s.hasPrefix("data:image/svg") { return true }
        if s.hasPrefix("data:image/gif") && s.count < 400 { return true }
        return false
    }

    /// WeChat / lazy-load: real URL is data-src, src is a 1×1 SVG. View has no site JS.
    /// Does not mutate the CAS archive.
    private func promoteLazyImages(_ html: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive]) else {
            return html
        }
        let ns = html as NSString
        let matches = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }
        var out = ""
        var cursor = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            var tag = ns.substring(with: m.range)
            let src = htmlAttr(tag, "src") ?? ""
            let real = ["data-src", "data-original", "data-lazy-src", "data-actualsrc"]
                .compactMap { htmlAttr(tag, $0) }
                .map { $0.hasPrefix("//") ? "https:\($0)" : $0 }
                .first { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
            if let real, isPlaceholderImageSrc(src) {
                if htmlAttr(tag, "src") != nil,
                   let srcRe = try? NSRegularExpression(pattern: #"(?i)\bsrc\s*=\s*"[^"]*""#) {
                    tag = srcRe.stringByReplacingMatches(
                        in: tag,
                        range: NSRange(location: 0, length: (tag as NSString).length),
                        withTemplate: "src=\"\(real)\""
                    )
                } else {
                    tag = tag.replacingOccurrences(of: "<img", with: "<img src=\"\(real)\"", options: .caseInsensitive)
                }
            }
            out += tag
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { out += ns.substring(from: cursor) }
        return out
    }

    /// View-time only: add a clickable watch link after YouTube/Vimeo iframes.
    /// Does not mutate the CAS archive.
    private func decorateArchiveMedia(_ html: String) -> String {
        let pattern = #"<iframe[^>]+src="(https://(?:www\.youtube(?:-nocookie)?\.com/embed/|player\.vimeo\.com/video/)([^"?]+))"[^>]*>\s*</iframe>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }
        let ns = html as NSString
        let matches = re.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }
        var out = ""
        var cursor = 0
        for m in matches {
            let full = m.range
            out += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            out += ns.substring(with: full)
            let hostPath = ns.substring(with: m.range(at: 1))
            let id = ns.substring(with: m.range(at: 2))
            let watch: String
            if hostPath.contains("vimeo") {
                watch = "https://vimeo.com/\(id)"
            } else {
                watch = "https://www.youtube.com/watch?v=\(id)"
            }
            let title: String = {
                let chunk = ns.substring(with: full)
                if let tm = chunk.range(of: #"title="([^"]+)""#, options: .regularExpression) {
                    let raw = String(chunk[tm])
                    if let q1 = raw.firstIndex(of: "\""), let q2 = raw.lastIndex(of: "\""), q1 < q2 {
                        let inner = raw[raw.index(after: q1)..<q2]
                        if !inner.isEmpty { return htmlEscapeText(String(inner)) }
                    }
                }
                return "Watch video"
            }()
            out += "<p class=\"cv-video-fallback\"><a href=\"\(watch)\" rel=\"noreferrer\">\(title)</a></p>"
            cursor = full.location + full.length
        }
        if cursor < ns.length {
            out += ns.substring(from: cursor)
        }
        return out
    }

    /// GET /api/archive/reader?id= — projected learning state + ops.
    private func sendReaderBundle(path: String, connection: HTTPByteSink) {
        guard let comps = URLComponents(string: "http://localhost\(path)"),
              let idStr = comps.queryItems?.first(where: { $0.name == "id" })?.value,
              let uuid = UUID(uuidString: idStr) else {
            sendJSON(["ok": false, "message": "expected ?id="], connection: connection)
            return
        }
        let bundle = database.fetchReaderBundle(id: uuid)
        sendJSON([
            "ok": true,
            "id": uuid.uuidString,
            "state": bundle.state,
            "ops": bundle.ops,
        ], connection: connection)
    }

    /// POST /api/clips/link  { fromId, toId?, toHash?, kind?, linked? }
    /// Judgment write. No SSE `update` — caller patches from+peer.
    private func handleClipLink(data: Data, connection: HTTPByteSink) {
        guard let obj = jsonBody(from: data),
              let fromRaw = obj["fromId"] as? String,
              let fromId = UUID(uuidString: fromRaw) else {
            sendJSON(["ok": false, "message": "expected {fromId, toId?|toHash?}"], connection: connection)
            return
        }
        let toId = (obj["toId"] as? String).flatMap { UUID(uuidString: $0) }
        let toHash = obj["toHash"] as? String
        let kind = obj["kind"] as? String
        var linked = true
        if let b = obj["linked"] as? Bool {
            linked = b
        } else if let n = obj["linked"] as? NSNumber {
            linked = n.boolValue
        }
        database.submitClipLink(fromId: fromId, toId: toId, toHash: toHash, kind: kind, linked: linked, source: "web") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let out):
                if out.changed, let opId = out.opId, let action = out.action {
                    CloudDocsSyncService.shared?.recordLocalClipLink(
                        opId: opId,
                        action: action,
                        fromId: out.fromId,
                        toContentHash: out.toContentHash,
                        toItemId: out.toItemId,
                        toIsNote: out.toIsNote,
                        kind: out.kind,
                        pairKey: out.pairKey,
                        ts: out.ts
                    )
                }
                var payload: [String: Any] = [
                    "ok": true,
                    "item": self.itemToJSON(out.item),
                ]
                if let peer = out.peerItem {
                    payload["peerItem"] = self.itemToJSON(peer)
                } else {
                    payload["peerItem"] = NSNull()
                }
                payload["link"] = out.link ?? NSNull()
                self.sendJSON(payload, connection: connection)
            case .failure(let err):
                let msg = err.errorDescription ?? "关联失败"
                self.sendJSON(["ok": false, "message": msg], connection: connection)
            }
        }
    }

    /// GET /api/items/{uuid}/links
    private func sendItemLinks(path: String, connection: HTTPByteSink) {
        let pathOnly = path.split(separator: "?").map(String.init).first ?? path
        let parts = pathOnly.split(separator: "/").map(String.init)
        guard parts.count >= 4,
              let uuid = UUID(uuidString: parts[2]) else {
            sendJSON(["ok": false, "message": "bad id"], connection: connection)
            return
        }
        let comps = URLComponents(string: "http://localhost" + path)
        let limit = comps?.queryItems?.first(where: { $0.name == "limit" }).flatMap { Int($0.value ?? "") } ?? 32
        database.fetchClipLinks(itemId: uuid, limit: limit) { [weak self] item, links in
            guard let self else { return }
            self.sendJSON([
                "ok": true,
                "id": uuid.uuidString,
                "linkCount": item?.linkCount ?? links.count,
                "links": links,
            ], connection: connection)
        }
    }

    private func sharePublicURL(headers: [String: String], token: String) -> String {
        let rawHost = headers["x-forwarded-host"] ?? headers["host"] ?? "127.0.0.1"
        let host = rawHost.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.first ?? "127.0.0.1"
        let xf = (headers["x-forwarded-proto"] ?? "").lowercased()
        let proto: String
        if xf.contains("https") {
            proto = "https"
        } else if host.contains("xyz69.top") || host.contains("guohuasun.com") {
            proto = "https"
        } else {
            proto = "http"
        }
        let local = host.hasPrefix("127.0.0.1") || host.hasPrefix("localhost") || host.hasPrefix("[::1]")
        let prefix = local ? "" : Self.publicPathPrefix
        return "\(proto)://\(host)\(prefix)/s/\(token)"
    }

    private func handleSharePage(pathOnly: String, connection: HTTPByteSink) {
        let token = String(pathOnly.dropFirst(3))
        guard ShareLinks.isToken(token), let rec = database.lookupShare(token: token) else {
            sendBinary(
                status: 404,
                reason: "Not Found",
                contentType: "text/html; charset=utf-8",
                body: Data(ShareLinks.goneHTML().utf8),
                connection: connection,
                extraHeaders: [("Cache-Control", "no-store")]
            )
            return
        }
        let html = ShareLinks.pageHTML(rec, archiveHTML: rec.kind == "archive" ? rec.snapshotBody : nil)
        sendBinary(
            status: 200,
            reason: "OK",
            contentType: "text/html; charset=utf-8",
            body: Data(html.utf8),
            connection: connection,
            extraHeaders: [("Cache-Control", "private, no-store"), ("X-Robots-Tag", "noindex")]
        )
    }

    private func handleShareAsset(path: String, connection: HTTPByteSink) {
        guard let comps = URLComponents(string: "http://localhost\(path)"),
              let token = comps.queryItems?.first(where: { $0.name == "t" })?.value,
              ShareLinks.isToken(token),
              let rec = database.lookupShare(token: token) else {
            sendErrorResponse(connection: connection, status: 404, message: "not found")
            return
        }
        if let sha = comps.queryItems?.first(where: { $0.name == "sha" })?.value?.lowercased(),
           ArchiveImageInliner.isAssetSHA(sha) {
            guard ShareLinks.allowsAsset(rec, sha: sha) else {
                sendErrorResponse(connection: connection, status: 404, message: "not found")
                return
            }
            sendArchiveAsset(path: "/api/archive/asset?sha=\(sha)", connection: connection)
            return
        }
        if rec.kind == "clip", rec.snapshotType == "image",
           let uuid = UUID(uuidString: rec.itemId) {
            sendImage(path: "/api/image?id=\(uuid.uuidString)&size=full", connection: connection)
            return
        }
        sendErrorResponse(connection: connection, status: 404, message: "not found")
    }

    private func handleShareCreate(data: Data, headers: [String: String], connection: HTTPByteSink) {
        guard let obj = jsonBody(from: data),
              let idStr = obj["id"] as? String,
              let uuid = UUID(uuidString: idStr) else {
            sendJSON(["ok": false, "message": "expected {id}"], connection: connection)
            return
        }
        database.fetchItem(id: uuid) { [weak self] item in
            guard let self else { return }
            guard let item else {
                self.sendJSON(["ok": false, "message": "条目不存在"], connection: connection)
                return
            }
            self.database.createOrGetShare(item: item) { rec in
                guard let rec else {
                    self.sendJSON(["ok": false, "message": "无法分享"], connection: connection)
                    return
                }
                let url = self.sharePublicURL(headers: headers, token: rec.token)
                self.sendJSON([
                    "ok": true,
                    "url": url,
                    "token": rec.token,
                    "kind": rec.kind,
                ], connection: connection)
            }
        }
    }

    private func handleShareRevoke(data: Data, connection: HTTPByteSink) {
        guard let obj = jsonBody(from: data),
              let idStr = obj["id"] as? String,
              let uuid = UUID(uuidString: idStr) else {
            sendJSON(["ok": false, "message": "expected {id}"], connection: connection)
            return
        }
        database.revokeShares(itemId: uuid) { n in
            self.sendJSON(["ok": true, "revoked": n], connection: connection)
        }
    }

    /// POST /api/clips/pin  { id, pinned? }  omitted pinned = toggle
    private func handleClipPin(data: Data, connection: HTTPByteSink) {
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard let brace = raw.range(of: "{"),
              let jsonData = raw[brace.lowerBound...].data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let idStr = obj["id"] as? String,
              let uuid = UUID(uuidString: idStr) else {
            sendJSON(["ok": false, "message": "expected {id, pinned?}"], connection: connection)
            return
        }
        func apply(_ pinned: Bool) {
            database.setPinned(id: uuid, pinned: pinned) { [weak self] item in
                guard let self else { return }
                if let item {
                    CloudDocsSyncService.shared?.recordLocalPin(
                        itemId: uuid,
                        pinned: pinned,
                        pinnedAt: item.pinnedAt
                    )
                    self.broadcastSSE(event: "clip_pinned", id: uuid.uuidString, extra: [
                        "pinned": pinned
                    ])
                    self.sendJSON(["ok": true, "item": self.itemToJSON(item)], connection: connection)
                } else {
                    self.sendJSON(["ok": false, "message": "置顶失败"], connection: connection)
                }
            }
        }
        if let pinned = obj["pinned"] as? Bool {
            apply(pinned)
        } else {
            database.fetchItem(id: uuid) { [weak self] item in
                guard self != nil else { return }
                apply(item?.pinnedAt == nil)
            }
        }
    }

    /// POST /api/archive/reader  { id, kind, payload? }
    private func handleReaderPost(data: Data, connection: HTTPByteSink) {
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard let brace = raw.range(of: "{"),
              let jsonData = raw[brace.lowerBound...].data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let idStr = obj["id"] as? String,
              let uuid = UUID(uuidString: idStr),
              let kind = obj["kind"] as? String else {
            sendJSON(["ok": false, "message": "expected {id, kind, payload?}"], connection: connection)
            return
        }
        let payload = obj["payload"] as? [String: Any] ?? [:]
        let source = (obj["source"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "web"
        database.appendReaderOp(itemId: uuid, kind: kind, payload: payload, source: source) { [weak self] state, opId, storedPayload in
            guard let self else { return }
            if state != nil, let opId {
                CloudDocsSyncService.shared?.recordLocalReaderOp(
                    itemId: uuid,
                    opId: opId,
                    kind: kind,
                    payload: storedPayload ?? payload,
                    ts: Date().timeIntervalSince1970,
                    source: source
                )
                let bundle = self.database.fetchReaderBundle(id: uuid)
                self.sendJSON(["ok": true, "state": bundle.state, "ops": bundle.ops], connection: connection)
            } else {
                self.sendJSON(["ok": false, "message": "无法写入阅读记录"], connection: connection)
            }
        }
    }

    /// GET /api/archive?job=  or /api/archive/{jobId}
    private func sendArchiveStatus(path: String, connection: HTTPByteSink) {
        guard let archive else {
            sendJSON(["ok": false, "message": "归档服务未启动"], connection: connection)
            return
        }
        var jobId: String?
        if let comps = URLComponents(string: "http://localhost\(path)") {
            jobId = comps.queryItems?.first(where: { $0.name == "job" || $0.name == "id" })?.value
        }
        if jobId == nil {
            let parts = path.split(separator: "/").map(String.init)
            if parts.count >= 3, parts[0].isEmpty || parts[0] == "api" {
                // /api/archive/{uuid}
                if let last = parts.last, last != "archive", last.count > 8 { jobId = last }
            }
        }
        guard let jobId, let job = archive.job(id: jobId) else {
            sendJSON(["ok": false, "message": "job not found"], connection: connection)
            return
        }
        sendJSON(["ok": true, "job": job.json()], connection: connection)
    }

    /// POST /api/clips/evaluate  { id, rating?, note? }
    /// Append-only evaluation history; updates latest projection only. Capture payload immutable.
    private func handleClipEvaluate(data: Data, connection: HTTPByteSink) {
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard let brace = raw.range(of: "{"),
              let jsonData = raw[brace.lowerBound...].data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let idStr = obj["id"] as? String,
              let uuid = UUID(uuidString: idStr) else {
            sendJSON(["ok": false, "message": "expected {id, rating?, note?}"], connection: connection)
            return
        }
        var rating: Double?
        if let r = obj["rating"] as? Double { rating = r }
        else if let r = obj["rating"] as? Int { rating = Double(r) }
        else if let r = obj["rating"] as? NSNumber { rating = r.doubleValue }
        let note = obj["note"] as? String

        database.submitEvaluation(id: uuid, rating: rating, note: note, source: "web") { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let pair):
                CloudDocsSyncService.shared?.recordLocalUserEvaluation(
                    item: pair.item,
                    evaluationId: pair.evaluationId,
                    rating: pair.item.userRating ?? rating,
                    note: note
                )
                // Do not broadcast full-list SSE "update" — avoids masonry re-layout storm.
                self.sendJSON([
                    "ok": true,
                    "evaluationId": pair.evaluationId,
                    "item": self.itemToJSON(pair.item)
                ], connection: connection)
            case .failure(let err):
                let msg = (err as? LocalizedError)?.errorDescription ?? err.localizedDescription
                self.sendJSON(["ok": false, "message": msg], connection: connection)
            }
        }
    }

    /// Legacy alias → evaluate
    private func handleClipContext(data: Data, connection: HTTPByteSink) {
        handleClipEvaluate(data: data, connection: connection)
    }

    private func sendItemEvaluations(path: String, connection: HTTPByteSink) {
        // /api/items/{uuid}/evaluations
        let parts = path.split(separator: "/").map(String.init)
        // ["api","items","{id}","evaluations"]
        guard parts.count >= 4,
              let uuid = UUID(uuidString: parts[2]) else {
            sendJSON(["ok": false, "message": "bad id"], connection: connection)
            return
        }
        database.fetchEvaluations(itemId: uuid, limit: 100) { [weak self] rows in
            self?.sendJSON(["ok": true, "evaluations": rows], connection: connection)
        }
    }

    /// Paginated list. Supports:
    ///   /api/clips?limit=30&cursor={ts}:{id}&q=keyword
    /// Response envelope (always object for new clients):
    ///   { "items": [...], "nextCursor": "..." | null }
    /// Legacy: still works when limit/cursor omitted (returns first page).
    private func sendItemsJSON(path: String, connection: HTTPByteSink) {
        let comps = URLComponents(string: "http://localhost\(path)")
        let items = comps?.queryItems ?? []
        let limit = items.first(where: { $0.name == "limit" }).flatMap { Int($0.value ?? "") } ?? 30
        let cursorRaw = items.first(where: { $0.name == "cursor" })?.value
        let cursor = cursorRaw.flatMap { ClipCursor.decode($0) }
        let q = Self.formQueryValue(path: path, name: "q")
            ?? items.first(where: { $0.name == "q" })?.value
        let view = items.first(where: { $0.name == "view" })?.value
        let trashOnly = (view == "trash")
        let typeFilter = items.first(where: { $0.name == "type" })?.value
        let excludeType = items.first(where: { $0.name == "exclude" })?.value
        let headOnly = (items.first(where: { $0.name == "fields" })?.value == "head")
        if let idStr = items.first(where: { $0.name == "id" })?.value, let uuid = UUID(uuidString: idStr) {
            database.fetchItem(id: uuid) { [weak self] item in
                guard let self else { return }
                // View document is GET /api/archive/view — never ship article HTML in clip JSON.
                let arr = item.map { [self.itemToJSON($0, includeArchiveHTML: false)] } ?? []
                self.sendJSON(["items": arr, "count": arr.count, "nextCursor": NSNull()], connection: connection)
            }
            return
        }
        if let hashRaw = items.first(where: { $0.name == "hash" })?.value {
            database.fetchItemByContentHash(hashRaw) { [weak self] item in
                guard let self else { return }
                let arr = item.map { [self.itemToJSON($0, includeArchiveHTML: false)] } ?? []
                self.sendJSON(["items": arr, "count": arr.count, "nextCursor": NSNull()], connection: connection)
            }
            return
        }

        database.fetchPage(limit: limit, cursor: cursor, query: q, trashOnly: trashOnly, typeFilter: typeFilter, excludeType: excludeType) { [weak self] page in
            guard let self = self else { return }
            let jsonItems = page.items.map { self.itemToJSON($0, headOnly: headOnly) }
            var payload: [String: Any] = [
                "items": jsonItems,
                "nextCursor": page.nextCursor?.encode() as Any
            ]
            // Keep flat array under "legacy" optional? No — clients updated.
            // Also expose count for debugging
            payload["count"] = jsonItems.count

            self.sendJSON(payload, connection: connection)
        }
    }

    private func sendBinary(status: Int, reason: String, contentType: String, body: Data, connection: HTTPByteSink, extraHeaders: [(String, String)] = []) {
        _ = reason
        var headers: [(String, String)] = [
            ("Access-Control-Allow-Origin", "*"),
            ("Content-Type", contentType),
            ("Content-Length", "\(body.count)")
        ]
        var hasCache = false
        for h in extraHeaders {
            if h.0.lowercased() == "cache-control" { hasCache = true }
            headers.append(h)
        }
        if !hasCache {
            headers.append(("Cache-Control", "no-store"))
        }
        let payload = OriginWire.encodeResponse(status: status, headers: headers, body: body, stream: false)
        connection.watchPeerClose {}
        connection.send(content: payload) { _ in }
    }

    private func detectImageContentType(_ data: Data) -> String {
        if data.count >= 8, data[0] == 0x89, data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47 {
            return "image/png"
        }
        if data.count >= 3, data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF {
            return "image/jpeg"
        }
        if data.count >= 6 {
            let sig6 = String(data: data.prefix(6), encoding: .ascii) ?? ""
            if sig6 == "GIF87a" || sig6 == "GIF89a" { return "image/gif" }
        }
        if data.count >= 2, data[0] == 0x49, data[1] == 0x49 { return "image/tiff" }
        if data.count >= 2, data[0] == 0x4D, data[1] == 0x4D { return "image/tiff" }
        if data.count >= 12 {
            let brand = String(data: data[4..<8], encoding: .ascii) ?? ""
            if brand == "ftyp" { return "image/heic" }
        }
        return "application/octet-stream"
    }

    private enum ImageSizeTier: String {
        case thumb   // feed card
        case medium  // optional mid
        case full    // lightbox / download
    }

    private func convertToPNG(_ data: Data) -> Data? {
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetCount(src) > 0 {
            let uti = CGImageSourceGetType(src) as String?
            if uti == "public.png" { return data }
            if let cgImage = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: true] as CFDictionary) {
                let out = NSMutableData()
                if let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, cgImage, nil)
                    if CGImageDestinationFinalize(dest) { return out as Data }
                }
            }
        }
        if let image = NSImage(data: data),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let converted = rep.representation(using: .png, properties: [:]) {
            return converted
        }
        return nil
    }

    /// Feed thumbs scale by **short** edge (and crop tall strips to the top 4:3).
    /// ImageIO `ThumbnailMaxPixelSize` is a long-edge cap and turns scrolling
    /// shots into a ~25px sliver.
    private func encodeImage(_ data: Data, tier: ImageSizeTier) -> (Data, String)? {
        if tier == .full {
            let ct = detectImageContentType(data)
            if ct == "image/png" || ct == "image/jpeg" || ct == "image/gif" || ct == "image/webp" {
                return (data, ct)
            }
            if let png = convertToPNG(data) { return (png, "image/png") }
            return (data, ct)
        }

        let maxShort: CGFloat = tier == .thumb ? 640 : 1200
        if let preview = ImageStoragePolicy.encodePreview(
            data,
            maxShort: maxShort,
            cropTallToCard: tier == .thumb
        ) {
            return preview
        }
        return convertToPNG(data).map { ($0, "image/png") }
    }

    private func sendImage(path: String, connection: HTTPByteSink) {
        guard let comps = URLComponents(string: "http://localhost\(path)") else {
            sendErrorResponse(connection: connection, status: 400, message: "Bad Request")
            return
        }
        let sizeRaw = comps.queryItems?.first(where: { $0.name == "size" })?.value ?? "full"
        let tier = ImageSizeTier(rawValue: sizeRaw) ?? .full

        if let sha = comps.queryItems?.first(where: { $0.name == "sha" })?.value?.lowercased(),
           ArchiveImageInliner.isAssetSHA(sha) {
            loadClipImageBytes(sha: sha) { [weak self] data in
                self?.finishSendImage(data, tier: tier, connection: connection)
            }
            return
        }

        guard let idValue = comps.queryItems?.first(where: { $0.name == "id" })?.value,
              let uuid = UUID(uuidString: idValue) else {
            sendErrorResponse(connection: connection, status: 400, message: "Bad Request")
            return
        }

        loadClipImageBytes(id: uuid) { [weak self] data in
            self?.finishSendImage(data, tier: tier, connection: connection)
        }
    }

    private func finishSendImage(_ data: Data?, tier: ImageSizeTier, connection: HTTPByteSink) {
        guard let data, data.count > 16 else {
            sendErrorResponse(connection: connection, status: 404, message: "Not Found")
            return
        }
        guard let (body, contentType) = encodeImage(data, tier: tier) else {
            sendErrorResponse(connection: connection, status: 500, message: "Encode Failed")
            return
        }
        let cache = tier == .full ? "private, max-age=120" : "private, max-age=86400"
        sendBinary(
            status: 200,
            reason: "OK",
            contentType: contentType,
            body: body,
            connection: connection,
            extraHeaders: [("Cache-Control", cache), ("X-Image-Size", tier.rawValue)]
        )
    }
    

    // MARK: - CloudDocs backup API

    private func jsonBody(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func sendJSONObject(_ obj: [String: Any], connection: HTTPByteSink) {
        sendJSON(obj, connection: connection)
    }

    private func sendBackupStatus(path: String, connection: HTTPByteSink) {
        let lite = (Self.formQueryValue(path: path, name: "lite") == "1")
        guard let backup = backup ?? CloudDocsBackupService.shared else {
            sendJSONObject([
                "enabled": false,
                "cloudDocsAvailable": false,
                "error": "backup service not started",
                "scheme": "CloudDocs"
            ], connection: connection)
            return
        }
        backup.statusSnapshot(lite: lite) { status in
            // Encode via JSONEncoder for nested Codable
            if let data = try? JSONEncoder().encode(status),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.sendJSONObject(obj, connection: connection)
            } else {
                self.sendErrorResponse(connection: connection, status: 500, message: "status encode failed")
            }
        }
    }

    private func handleBackupConfig(data: Data, connection: HTTPByteSink) {
        guard let backup = backup ?? CloudDocsBackupService.shared else {
            sendErrorResponse(connection: connection, status: 503, message: "backup unavailable")
            return
        }
        guard let json = jsonBody(from: data) else {
            sendErrorResponse(connection: connection, status: 400, message: "Bad Request")
            return
        }
        backup.updateConfig(json) { _ in
            backup.statusSnapshot { status in
                if let data = try? JSONEncoder().encode(status),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.sendJSONObject(obj, connection: connection)
                } else {
                    self.sendJSONObject(["ok": true], connection: connection)
                }
            }
        }
    }

    private func handleBackupRun(connection: HTTPByteSink) {
        guard let backup = backup ?? CloudDocsBackupService.shared else {
            sendErrorResponse(connection: connection, status: 503, message: "backup unavailable")
            return
        }
        backup.runNow { ok, msg in
            self.sendJSONObject(["ok": ok, "message": msg], connection: connection)
        }
    }

    private func handleBackupRestore(data: Data, connection: HTTPByteSink) {
        guard let backup = backup ?? CloudDocsBackupService.shared else {
            sendErrorResponse(connection: connection, status: 503, message: "backup unavailable")
            return
        }
        let json = jsonBody(from: data) ?? [:]
        let id = (json["id"] as? String) ?? (json["snapshot"] as? String) ?? "latest"
        backup.restore(snapshotId: id) { ok, msg in
            self.sendJSONObject(["ok": ok, "message": msg, "id": id], connection: connection)
        }
    }

    private func sendErrorResponse(connection: HTTPByteSink, status: Int, message: String) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>\(status) \(message)</title></head>
        <body><h1>\(status) \(message)</h1></body>
        </html>
        """
        sendBinary(
            status: status,
            reason: message,
            contentType: "text/html; charset=utf-8",
            body: Data(html.utf8),
            connection: connection,
            extraHeaders: [("Cache-Control", "no-store")]
        )
    }
    
    deinit {
        stop()
    }
}

/// One loopback Trae `/api/stream` fan-in onto wall `/api/events`.
/// Browser HTTP/1.1 allows ~6 connections per host; a second EventSource
/// per tab (`/trae/api/stream`) starves notes/sessions fetches on later windows.
final class TraeAskFanIn: NSObject, URLSessionDataDelegate {
    static let shared = TraeAskFanIn()
    private weak var server: WebServer?
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buf = Data()
    private var retryWork: DispatchWorkItem?
    private var retrySec: Double = 2

    func attach(_ server: WebServer) {
        self.server = server
        start()
    }

    private func start() {
        lock.lock()
        retryWork?.cancel()
        task?.cancel()
        session?.invalidateAndCancel()
        session = nil
        task = nil
        buf.removeAll(keepingCapacity: true)
        lock.unlock()
        guard let url = WebServer.traeBackendURL(from: "/trae/api/stream") else { return }
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 86400
        config.timeoutIntervalForResource = 86400
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        var req = URLRequest(url: url)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let task = session.dataTask(with: req)
        self.task = task
        task.resume()
        print("[SSE] trae ask fan-in \(url.absoluteString)")
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buf.append(data)
        retrySec = 2
        var frames: [Data] = []
        let sep = Data("\n\n".utf8)
        while let range = buf.range(of: sep) {
            frames.append(buf.subdata(in: buf.startIndex..<range.lowerBound))
            buf.removeSubrange(buf.startIndex..<range.upperBound)
        }
        lock.unlock()
        for frame in frames { emitIfAsk(frame) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        scheduleRetry()
    }

    private func emitIfAsk(_ frame: Data) {
        guard let text = String(data: frame, encoding: .utf8) else { return }
        var payload = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let rest = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if !payload.isEmpty { payload += "\n" }
            payload += rest
        }
        guard !payload.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              obj["needs_user"] as? Bool == true else { return }
        var extra = obj
        extra.removeValue(forKey: "type")
        server?.broadcastSSE(event: "trae_ask", id: obj["event_id"] as? String, extra: extra)
    }

    private func scheduleRetry() {
        lock.lock()
        let wait = retrySec
        retrySec = min(15, retrySec * 1.6)
        lock.unlock()
        let work = DispatchWorkItem { [weak self] in self?.start() }
        retryWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + wait, execute: work)
    }
}

/// Streams Trae `/api/stream` onto a ClipVault client connection without buffering.
final class TraeStreamPipe: NSObject, URLSessionDataDelegate {
    private let client: HTTPByteSink
    private let url: URL
    private let lock = NSLock()
    private var headerSent = false
    private var dead = false
    private var session: URLSession?
    private var task: URLSessionDataTask?

    init(client: HTTPByteSink, url: URL) {
        self.client = client
        self.url = url
        super.init()
    }

    func start() {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 86400
        config.timeoutIntervalForResource = 86400
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        var req = URLRequest(url: url)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let task = session.dataTask(with: req)
        self.task = task
        watchClient()
        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        let ctype = http?.value(forHTTPHeaderField: "Content-Type")
            ?? "text/event-stream; charset=utf-8"
        sendHeader(status: status, contentType: ctype)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !headerSent {
            sendHeader(status: 200, contentType: "text/event-stream; charset=utf-8")
        }
        send(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !headerSent {
            let body = Data(#"{"error":"trae store unreachable"}"#.utf8)
            sendHeader(status: 502, contentType: "application/json; charset=utf-8", contentLength: body.count)
            send(body)
        }
        close()
    }

    private func sendHeader(status: Int, contentType: String, contentLength: Int? = nil) {
        lock.lock()
        if headerSent || dead {
            lock.unlock()
            return
        }
        headerSent = true
        lock.unlock()
        var headers: [(String, String)] = [
            ("Content-Type", contentType),
            ("Cache-Control", "no-cache, no-transform"),
            ("X-Accel-Buffering", "no"),
            ("Access-Control-Allow-Origin", "*"),
        ]
        if let contentLength {
            headers.append(("Content-Length", "\(contentLength)"))
        }
        send(OriginWire.encodeResponse(status: status, headers: headers, body: Data(), stream: true))
    }

    private func send(_ data: Data) {
        lock.lock()
        if dead {
            lock.unlock()
            return
        }
        lock.unlock()
        client.send(content: data) { [weak self] error in
            if error != nil { self?.close() }
        }
    }

    private func watchClient() {
        client.watchPeerClose { [weak self] in
            self?.close()
        }
    }

    private func close() {
        lock.lock()
        if dead {
            lock.unlock()
            return
        }
        dead = true
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        session = nil
        client.cancel()
    }
}

// 使用 ViewModel 文件中定义的 NSImage.pngData 扩展
