import Foundation
import Network
import AppKit
import ImageIO
import CoreGraphics

class WebServer {
    private var listener: NWListener?
    private let port: UInt16
    private let database: DatabaseManager
    private let backup: CloudDocsBackupService?
    private let sync: CloudDocsSyncService?
    private let archive: WebArchiveService?
    private var sseConnections: [NWConnection] = []
    
    var isRunning: Bool {
        listener != nil
    }

    init(
        port: UInt16 = 8080,
        database: DatabaseManager = DatabaseManager(),
        backup: CloudDocsBackupService? = nil,
        sync: CloudDocsSyncService? = nil,
        archive: WebArchiveService? = nil
    ) {
        self.port = port
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
        guard listener == nil else { return }
        
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        
        do {
            guard let port = NWEndpoint.Port(rawValue: port) else { return }
            listener = try NWListener(using: parameters, on: port)
            listener?.stateUpdateHandler = { [weak self] state in
                self?.handleStateUpdate(state)
            }
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            listener?.start(queue: DispatchQueue.global(qos: .userInitiated))

            // 剪贴板新增时推送 SSE，驱动前端实时刷新
            NotificationCenter.default.addObserver(
                forName: Notification.Name("ClipFlowItemAdded"),
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.broadcastSSE(event: "update")
            }
        } catch {
            print("Failed to start server: \(error)")
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
    }
    
    private func handleStateUpdate(_ state: NWListener.State) {
        switch state {
        case .ready:
            print("Web server started on port \(port)")
        case .failed(let error):
            print("Server failed: \(error)")
        case .cancelled:
            print("Server stopped")
        default:
            break
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if state == .ready {
                self.receiveRequest(from: connection)
            }
        }
        connection.start(queue: DispatchQueue.global())
    }
    
    private func receiveRequest(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, !data.isEmpty else {
                if isComplete || error != nil {
                    connection.cancel()
                }
                return
            }
            
            self.handleRequest(data: data, connection: connection)
        }
    }
    
    private func handleRequest(data: Data, connection: NWConnection) {
        let requestString = String(data: data, encoding: .utf8) ?? ""
        let lines = requestString.components(separatedBy: "\r\n")
        
        guard let firstLine = lines.first else {
            sendErrorResponse(connection: connection, status: 400, message: "Bad Request")
            return
        }
        
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendErrorResponse(connection: connection, status: 400, message: "Bad Request")
            return
        }
        
        let method = parts[0]
        let path = parts[1]
        
        let pathOnly = path.split(separator: "?", maxSplits: 1).map(String.init).first ?? path
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
        } else if method == "POST" && pathOnly == "/api/clips/pin" {
            handleClipPin(data: data, connection: connection)
        } else if method == "DELETE" && pathOnly.hasPrefix("/api/archive") {
            handleArchiveClear(path: path, connection: connection)
        } else if method == "DELETE" && pathOnly.hasPrefix("/api/clips") {
            handleDeleteClip(path: path, connection: connection)
        } else {
            sendErrorResponse(connection: connection, status: 405, message: "Method Not Allowed")
        }
    }
    
    private func handleOptionsRequest(connection: NWConnection) {
        let response = """
        HTTP/1.1 204 No Content
        Access-Control-Allow-Origin: *
        Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS
        Access-Control-Allow-Headers: Content-Type
        
        """
        sendResponse(response, connection: connection)
    }

    private func handleGetRequest(path: String, connection: NWConnection) {
        // path may include query string, e.g. /api/clips?cursor=...
        let pathOnly = path.split(separator: "?", maxSplits: 1).map(String.init).first ?? path
        if pathOnly == "/" || pathOnly == "/index.html" {
            sendHTMLResponse(connection: connection)
        } else if pathOnly == "/api/items" || pathOnly == "/api/clips" {
            sendItemsJSON(path: path, connection: connection)
        } else if pathOnly.hasPrefix("/api/image") {
            sendImage(path: path, connection: connection)
        } else if pathOnly == "/api/events" {
            handleSSEEvents(connection: connection)
        } else if pathOnly == "/api/backup/status" {
            sendBackupStatus(connection: connection)
        } else if pathOnly == "/api/backup/snapshots" {
            sendBackupStatus(connection: connection) // same payload includes snapshots
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
        } else if pathOnly == "/api/archive/view" {
            sendArchiveView(path: path, connection: connection)
        } else if pathOnly == "/api/archive/reader" {
            sendReaderBundle(path: path, connection: connection)
        } else if pathOnly == "/api/archive" || pathOnly.hasPrefix("/api/archive/") {
            sendArchiveStatus(path: path, connection: connection)
        } else if pathOnly.hasPrefix("/assets/") {
            sendStaticAsset(pathOnly: pathOnly, connection: connection)
        } else {
            sendErrorResponse(connection: connection, status: 404, message: "Not Found")
        }
    }

    private func handleSSEEvents(connection: NWConnection) {
        let headers: [(String, String)] = [
            ("Content-Type", "text/event-stream"),
            ("Cache-Control", "no-cache"),
            ("Connection", "keep-alive"),
            ("Access-Control-Allow-Origin", "*")
        ]
        var payload = httpHeader(status: 200, reason: "OK", headers: headers)
        payload.append(contentsOf: Data("data: {\"type\":\"connected\"}\n\n".utf8))
        connection.send(content: payload, completion: .idempotent)
        sseConnections.append(connection)
    }

    func broadcastSSE(event: String, id: String? = nil) {
        var obj: [String: Any] = ["type": event]
        if let id = id, !id.isEmpty { obj["id"] = id }
        guard let json = try? JSONSerialization.data(withJSONObject: obj),
              let jsonStr = String(data: json, encoding: .utf8) else { return }
        let payload = "data: \(jsonStr)\n\n"
        guard let data = payload.data(using: .utf8) else { return }

        sseConnections.removeAll { conn in
            if conn.state == .cancelled || conn.state == .failed(NWError.posix(.ECANCELED)) {
                return true
            }
            conn.send(content: data, completion: .contentProcessed { _ in })
            return false
        }
    }

    private func handlePostClip(data: Data, connection: NWConnection) {
        // Find body in HTTP request
        let requestString = String(data: data, encoding: .utf8) ?? ""
        if let bodyRange = requestString.range(of: "\r\n\r\n") {
            let bodyString = String(requestString[bodyRange.upperBound...])
            if let bodyData = bodyString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
               let text = json["text"] as? String {
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
                let resp = """
                HTTP/1.1 200 OK
                Access-Control-Allow-Origin: *
                Content-Type: application/json
                
                {"status":"success"}
                """
                sendResponse(resp, connection: connection)
                return
            }
        }
        sendErrorResponse(connection: connection, status: 400, message: "Bad Request")
    }

    private func handleDeleteClip(path: String, connection: NWConnection) {
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
                let resp = """
                HTTP/1.1 200 OK
                Access-Control-Allow-Origin: *
                Content-Type: application/json
                
                {"status":"deleted","soft":true}
                """
                self.sendResponse(resp, connection: connection)
            } else {
                self.sendErrorResponse(connection: connection, status: 500, message: "Failed to delete")
            }
        }
    }

    
    private func handleRestoreClip(data: Data, connection: NWConnection) {
        let requestString = String(data: data, encoding: .utf8) ?? ""
        guard let bodyRange = requestString.range(of: "\r\n\r\n") else {
            sendErrorResponse(connection: connection, status: 400, message: "Bad Request")
            return
        }
        let bodyString = String(requestString[bodyRange.upperBound...])
        guard let bodyData = bodyString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let idValue = json["id"] as? String,
              let uuid = UUID(uuidString: idValue) else {
            sendErrorResponse(connection: connection, status: 400, message: "Bad Request")
            return
        }
        database.restoreItem(id: uuid) { [weak self] ok in
            guard let self = self else { return }
            if ok {
                self.broadcastSSE(event: "clip_restored", id: uuid.uuidString)
                let resp = """
                HTTP/1.1 200 OK
                Access-Control-Allow-Origin: *
                Content-Type: application/json
                
                {"status":"restored"}
                """
                self.sendResponse(resp, connection: connection)
            } else {
                self.sendErrorResponse(connection: connection, status: 404, message: "Not in trash")
            }
        }
    }

    private func sendOpLogs(path: String, connection: NWConnection) {
        let comps = URLComponents(string: "http://localhost" + path)
        let limit = comps?.queryItems?.first(where: { $0.name == "limit" }).flatMap { Int($0.value ?? "") } ?? 100
        database.fetchOperationLogs(limit: limit) { [weak self] rows in
            guard let self = self else { return }
            self.sendJSON(["items": rows, "count": rows.count], connection: connection)
        }
    }

    private func sendItemEvents(path: String, connection: NWConnection) {
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

    private func sendItemFrequency(path: String, connection: NWConnection) {
        let comps = URLComponents(string: "http://localhost" + path)
        if let hash = comps?.queryItems?.first(where: { $0.name == "hash" })?.value, !hash.isEmpty {
            database.contentFrequency(contentHash: hash) { [weak self] freq in
                self?.sendJSON(freq, connection: connection)
            }
            return
        }
        sendErrorResponse(connection: connection, status: 400, message: "hash query required")
    }

    private func sendSyncStatus(connection: NWConnection) {
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

    private func handleSyncNow(connection: NWConnection) {
        guard let sync = sync else {
            sendErrorResponse(connection: connection, status: 503, message: "sync not configured")
            return
        }
        sync.runNow { [weak self] ok, msg in
            guard let self = self else { return }
            self.sendJSON(["ok": ok, "message": msg], connection: connection)
        }
    }

    private func handleSyncConfig(data: Data, connection: NWConnection) {
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

    private func sendJSON(_ object: [String: Any], connection: NWConnection) {
        guard let body = try? JSONSerialization.data(withJSONObject: object),
              let bodyStr = String(data: body, encoding: .utf8) else {
            sendErrorResponse(connection: connection, status: 500, message: "JSON encode failed")
            return
        }
        let response = """
        HTTP/1.1 200 OK\r
        Access-Control-Allow-Origin: *\r
        Content-Type: application/json; charset=utf-8\r
        Content-Length: \(body.count)\r
        \r
        \(bodyStr)
        """
        sendResponse(response, connection: connection)
    }
    
    /// Serve files from ./web/assets (logo, favicon, etc.)
    private func sendStaticAsset(pathOnly: String, connection: NWConnection) {
        // pathOnly like /assets/keepsake-logo.jpg — prevent path traversal
        let name = pathOnly
            .replacingOccurrences(of: "/assets/", with: "")
            .replacingOccurrences(of: "..", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !name.isEmpty, !name.contains("/") else {
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
        default: ctype = "application/octet-stream"
        }
        sendBinary(
            status: 200,
            reason: "OK",
            contentType: ctype,
            body: data,
            connection: connection,
            extraHeaders: [("Cache-Control", "public, max-age=86400")]
        )
    }

    private func sendHTMLResponse(connection: NWConnection) {
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
    
    private func itemToJSON(_ item: ClipboardItem, includeArchiveHTML: Bool = false) -> [String: Any] {
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
        var archived = false
        if let metaStr = database.webArchiveMetaJSON(id: item.id),
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
        }
        // Thumb URL for image types — client never loads full blob in feed
        if item.type == .image {
            dict["thumbUrl"] = "/api/image?id=\(item.id.uuidString)&size=thumb"
            dict["fullUrl"] = "/api/image?id=\(item.id.uuidString)&size=full"
        }
        return dict
    }

    /// POST /api/archive  { url, itemId? }
    /// Manual web archive — WKWebView + Readability. Never auto.
    private func handleArchivePost(data: Data, connection: NWConnection) {
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
    private func handleArchiveClear(path: String, connection: NWConnection) {
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
    private func sendArchiveView(path: String, connection: NWConnection) {
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
            let doc = self.buildArchiveViewDocument(
                title: title,
                source: source,
                bodyHTML: html,
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
                    ("Content-Security-Policy", "default-src 'none'; img-src * data: blob:; style-src 'unsafe-inline' https://cdn.jsdelivr.net; font-src https://cdn.jsdelivr.net; script-src 'self'; connect-src 'self'"),
                    ("X-Content-Type-Options", "nosniff"),
                ]
            )
        }
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
          <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@picocss/pico@2/css/pico.classless.min.css"/>
          <style>
            .cv-bar{
              position:sticky;top:0;z-index:2;
              display:flex;flex-direction:column;gap:4px;
              padding:10px 18px 12px;
              background:#fff;border-bottom:0.5px solid #e5e5ea;
              font-family:-apple-system,BlinkMacSystemFont,system-ui,sans-serif;
            }
            .cv-bar h1{margin:0;font-size:15px;font-weight:650;letter-spacing:-0.02em;}
            .cv-bar p{margin:0;font-size:12px;color:#6e6e73;word-break:break-all;}
            main.cv-article{
              max-width:46rem;margin:0 auto;padding:1.25rem 1.25rem 4rem;
            }
            pre,pre code{
              white-space:pre !important;
              word-break:normal;
              overflow-wrap:normal;
              overflow:auto;
              font-variant-ligatures:none;
              font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
            }
            img,video{max-width:100%;height:auto;}
            a{pointer-events:none;color:inherit;text-decoration:none;}
          </style>
          <script src="/assets/archive-reader.js?v=20260814d" defer></script>
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

    /// GET /api/archive/reader?id= — projected learning state + ops.
    private func sendReaderBundle(path: String, connection: NWConnection) {
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

    /// POST /api/clips/pin  { id, pinned? }  omitted pinned = toggle
    private func handleClipPin(data: Data, connection: NWConnection) {
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
    private func handleReaderPost(data: Data, connection: NWConnection) {
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
        database.appendReaderOp(itemId: uuid, kind: kind, payload: payload, source: source) { [weak self] state in
            guard let self else { return }
            if let state {
                self.sendJSON(["ok": true, "state": state], connection: connection)
            } else {
                self.sendJSON(["ok": false, "message": "无法写入阅读记录"], connection: connection)
            }
        }
    }

    /// GET /api/archive?job=  or /api/archive/{jobId}
    private func sendArchiveStatus(path: String, connection: NWConnection) {
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
    private func handleClipEvaluate(data: Data, connection: NWConnection) {
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
    private func handleClipContext(data: Data, connection: NWConnection) {
        handleClipEvaluate(data: data, connection: connection)
    }

    private func sendItemEvaluations(path: String, connection: NWConnection) {
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
    private func sendItemsJSON(path: String, connection: NWConnection) {
        let comps = URLComponents(string: "http://localhost\(path)")
        let items = comps?.queryItems ?? []
        let limit = items.first(where: { $0.name == "limit" }).flatMap { Int($0.value ?? "") } ?? 30
        let cursorRaw = items.first(where: { $0.name == "cursor" })?.value
        let cursor = cursorRaw.flatMap { ClipCursor.decode($0) }
        let q = items.first(where: { $0.name == "q" })?.value
        let view = items.first(where: { $0.name == "view" })?.value
        let trashOnly = (view == "trash")
        if let idStr = items.first(where: { $0.name == "id" })?.value, let uuid = UUID(uuidString: idStr) {
            database.fetchItem(id: uuid) { [weak self] item in
                guard let self else { return }
                // View document is GET /api/archive/view — never ship article HTML in clip JSON.
                let arr = item.map { [self.itemToJSON($0, includeArchiveHTML: false)] } ?? []
                self.sendJSON(["items": arr, "count": arr.count, "nextCursor": NSNull()], connection: connection)
            }
            return
        }

        database.fetchPage(limit: limit, cursor: cursor, query: q, trashOnly: trashOnly) { [weak self] page in
            guard let self = self else { return }
            let jsonItems = page.items.map { self.itemToJSON($0) }
            var payload: [String: Any] = [
                "items": jsonItems,
                "nextCursor": page.nextCursor?.encode() as Any
            ]
            // Keep flat array under "legacy" optional? No — clients updated.
            // Also expose count for debugging
            payload["count"] = jsonItems.count

            do {
                let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [])
                let jsonString = String(data: jsonData, encoding: .utf8) ?? "{\"items\":[]}"
                let response = """
                HTTP/1.1 200 OK
                Access-Control-Allow-Origin: *
                Content-Type: application/json; charset=utf-8
                Content-Length: \(jsonString.utf8.count)

                \(jsonString)
                """
                self.sendResponse(response, connection: connection)
            } catch {
                self.sendErrorResponse(connection: connection, status: 500, message: "Internal Server Error")
            }
        }
    }

    /// Build HTTP/1.1 headers with mandatory CRLF and blank line before body.
    /// Swift multiline strings only emit LF, which breaks binary responses (e.g. PNG)
    /// because clients cannot locate the end of headers once the body starts with 0x89.
    private func httpHeader(status: Int, reason: String, headers: [(String, String)]) -> Data {
        var lines: [String] = ["HTTP/1.1 \(status) \(reason)"]
        lines.append(contentsOf: headers.map { "\($0.0): \($0.1)" })
        let text = lines.joined(separator: "\r\n") + "\r\n\r\n"
        return Data(text.utf8)
    }

    private func sendBinary(status: Int, reason: String, contentType: String, body: Data, connection: NWConnection, extraHeaders: [(String, String)] = []) {
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
            headers.append(("Cache-Control", "private, max-age=60"))
        }
        let payload = httpHeader(status: status, reason: reason, headers: headers) + body
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
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

        var maxPixel: CGFloat {
            switch self {
            case .thumb: return 360
            case .medium: return 1200
            case .full: return 0 // original
            }
        }
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

    /// Downscale with ImageIO thumbnail API (fast, stream-friendly).
    private func encodeImage(_ data: Data, tier: ImageSizeTier) -> (Data, String)? {
        if tier == .full {
            if let png = convertToPNG(data) { return (png, "image/png") }
            return (data, detectImageContentType(data))
        }

        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0 else {
            return convertToPNG(data).map { ($0, "image/png") }
        }

        let maxPx = tier.maxPixel
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPx,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return convertToPNG(data).map { ($0, "image/png") }
        }

        // Feed thumbs: JPEG for size; medium: JPEG too; full: PNG above
        let out = NSMutableData()
        let uti = "public.jpeg" as CFString
        guard let dest = CGImageDestinationCreateWithData(out, uti, 1, nil) else {
            return nil
        }
        let quality: CGFloat = tier == .thumb ? 0.72 : 0.85
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cgThumb, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, "image/jpeg")
    }

    private func sendImage(path: String, connection: NWConnection) {
        guard let comps = URLComponents(string: "http://localhost\(path)"),
              let idValue = comps.queryItems?.first(where: { $0.name == "id" })?.value,
              let uuid = UUID(uuidString: idValue) else {
            sendErrorResponse(connection: connection, status: 400, message: "Bad Request")
            return
        }
        let sizeRaw = comps.queryItems?.first(where: { $0.name == "size" })?.value ?? "full"
        let tier = ImageSizeTier(rawValue: sizeRaw) ?? .full

        database.fetchImageData(id: uuid) { [weak self] imageData in
            guard let self = self, let data = imageData, !data.isEmpty else {
                self?.sendErrorResponse(connection: connection, status: 404, message: "Not Found")
                return
            }

            // Resize off main-ish path (already on callback queue)
            guard let (body, contentType) = self.encodeImage(data, tier: tier) else {
                self.sendErrorResponse(connection: connection, status: 500, message: "Encode Failed")
                return
            }

            let cache = tier == .full ? "private, max-age=120" : "private, max-age=86400"
            self.sendBinary(
                status: 200,
                reason: "OK",
                contentType: contentType,
                body: body,
                connection: connection,
                extraHeaders: [("Cache-Control", cache), ("X-Image-Size", tier.rawValue)]
            )
        }
    }
    

    // MARK: - CloudDocs backup API

    private func jsonBody(from data: Data) -> [String: Any]? {
        let requestString = String(data: data, encoding: .utf8) ?? ""
        let bodyString: String
        if let r = requestString.range(of: "\r\n\r\n") {
            bodyString = String(requestString[r.upperBound...])
        } else if let r = requestString.range(of: "\n\n") {
            bodyString = String(requestString[r.upperBound...])
        } else {
            bodyString = requestString
        }
        guard let bodyData = bodyString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func sendJSONObject(_ obj: [String: Any], connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let jsonString = String(data: data, encoding: .utf8) else {
            sendErrorResponse(connection: connection, status: 500, message: "JSON encode failed")
            return
        }
        let response = """
        HTTP/1.1 200 OK
        Access-Control-Allow-Origin: *
        Content-Type: application/json; charset=utf-8
        Content-Length: \(jsonString.utf8.count)

        \(jsonString)
        """
        sendResponse(response, connection: connection)
    }

    private func sendBackupStatus(connection: NWConnection) {
        guard let backup = backup ?? CloudDocsBackupService.shared else {
            sendJSONObject([
                "enabled": false,
                "cloudDocsAvailable": false,
                "error": "backup service not started",
                "scheme": "CloudDocs"
            ], connection: connection)
            return
        }
        backup.statusSnapshot { status in
            // Encode via JSONEncoder for nested Codable
            if let data = try? JSONEncoder().encode(status),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.sendJSONObject(obj, connection: connection)
            } else {
                self.sendErrorResponse(connection: connection, status: 500, message: "status encode failed")
            }
        }
    }

    private func handleBackupConfig(data: Data, connection: NWConnection) {
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

    private func handleBackupRun(connection: NWConnection) {
        guard let backup = backup ?? CloudDocsBackupService.shared else {
            sendErrorResponse(connection: connection, status: 503, message: "backup unavailable")
            return
        }
        backup.runNow { ok, msg in
            self.sendJSONObject(["ok": ok, "message": msg], connection: connection)
        }
    }

    private func handleBackupRestore(data: Data, connection: NWConnection) {
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

    private func sendErrorResponse(connection: NWConnection, status: Int, message: String) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>\(status) \(message)</title></head>
        <body><h1>\(status) \(message)</h1></body>
        </html>
        """
        
        let response = """
        HTTP/1.1 \(status) \(message)
        Content-Type: text/html; charset=utf-8
        Content-Length: \(html.utf8.count)
        
        \(html)
        """
        
        sendResponse(response, connection: connection)
    }
    
    private func sendResponse(_ response: String, connection: NWConnection) {
        // Normalize any LF-only HTTP headers (from Swift multiline strings) to CRLF
        // so browsers and curl parse headers/body boundary correctly.
        let normalized: String
        if let range = response.range(of: "\n\n") {
            let headerPart = String(response[..<range.lowerBound]).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
            let bodyPart = String(response[range.upperBound...])
            normalized = headerPart + "\r\n\r\n" + bodyPart
        } else if let range = response.range(of: "\r\n\r\n") {
            normalized = response
            _ = range
        } else {
            normalized = response.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        }

        guard let data = normalized.data(using: .utf8) else {
            connection.cancel()
            return
        }
        
        connection.send(content: data, completion: .contentProcessed { [weak connection] _ in
            connection?.cancel()
        })
    }
    
    deinit {
        stop()
    }
}

// 使用 ViewModel 文件中定义的 NSImage.pngData 扩展
