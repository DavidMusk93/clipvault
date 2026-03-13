import Foundation
import Network
import AppKit

class WebServer {
    private var listener: NWListener?
    private let port: UInt16
    private let database: DatabaseManager
    
    var isRunning: Bool {
        listener != nil
    }

    init(port: UInt16 = 8080, database: DatabaseManager = DatabaseManager()) {
        self.port = port
        self.database = database
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
        
        if method == "GET" {
            handleGetRequest(path: path, connection: connection)
        } else {
            sendErrorResponse(connection: connection, status: 405, message: "Method Not Allowed")
        }
    }
    
    private func handleGetRequest(path: String, connection: NWConnection) {
        if path == "/" || path == "/index.html" {
            sendHTMLResponse(connection: connection)
        } else if path == "/api/items" {
            sendItemsJSON(connection: connection)
        } else if path.hasPrefix("/api/image") {
            sendImage(path: path, connection: connection)
        } else {
            sendErrorResponse(connection: connection, status: 404, message: "Not Found")
        }
    }
    
    private func sendHTMLResponse(connection: NWConnection) {
        let html = WebServer.indexHTML
        let response = """
        HTTP/1.1 200 OK
        Content-Type: text/html; charset=utf-8
        Content-Length: \(html.utf8.count)
        
        \(html)
        """
        sendResponse(response, connection: connection)
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
                <div class="header">
                    <h1>🦞 ClipFlow</h1>
                    <p>Your clipboard history, anywhere on your network</p>
                    <div class="search-bar">
                        <input type="text" id="searchInput" placeholder="Search clipboard history...">
                    </div>
                </div>
                <div class="items-list" id="itemsList">
                    <div class="empty-state">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                            <rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>
                            <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>
                        </svg>
                        <p>Loading clipboard history...</p>
                    </div>
                </div>
            </div>
            <script>
                \(indexJS)
            </script>
        </body>
        </html>
        """
    }

    private static var indexCSS: String {
        """
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            background: linear-gradient(180deg, rgba(249,249,252,1) 0%, rgba(240,241,244,1) 100%);
            min-height: 100vh; padding: 24px;
        }
        .container { max-width: 1000px; margin: 0 auto; }
        .header {
            background: rgba(255,255,255,0.85); border-radius: 12px; padding: 20px 24px;
            margin-bottom: 20px; box-shadow: 0 1px 3px rgba(0, 0, 0, 0.06);
        }
        .header h1 { color: #333; font-size: 28px; margin-bottom: 8px; }
        .header p { color: #666; }
        .search-bar { margin-top: 16px; }
        .search-bar input {
            width: 100%; padding: 12px 16px; border: 1px solid #d2d2d7; border-radius: 12px;
            font-size: 16px; transition: border-color 0.3s;
        }
        .search-bar input:focus { outline: none; border-color: #86868b; }
        .items-list { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 16px; }
        .item-card {
            background: rgba(255,255,255,0.85); border-radius: 12px; padding: 16px;
            border: 1px solid #e5e5ea; box-shadow: 0 1px 3px rgba(0, 0, 0, 0.06);
            transition: transform 0.2s, box-shadow 0.2s;
        }
        .item-card:hover { transform: translateY(-2px); box-shadow: 0 8px 12px rgba(0, 0, 0, 0.1); }
        .item-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; }
        .item-type {
            display: inline-block; padding: 4px 12px; border-radius: 999px; font-size: 12px;
            font-weight: 600; text-transform: uppercase; background: #f5f5f7; color: #1d1d1f;
        }
        .item-time { color: #999; font-size: 13px; }
        .item-preview { color: #333; line-height: 1.6; word-break: break-word; }
        .thumb { width:100%; height:180px; object-fit:cover; border-radius:12px; border:1px solid #e5e5ea; background:#fff; }
        .item-source { margin-top: 8px; color: #666; font-size: 13px; }
        .empty-state {
            background: rgba(255,255,255,0.85); border-radius: 12px; padding: 60px 20px;
            text-align: center; color: #666;
        }
        .empty-state svg { width: 80px; height: 80px; margin-bottom: 16px; opacity: 0.5; }
        """
    }

    private static var indexJS: String {
        """
        let allItems = [];
        async function loadItems() {
            try {
                const response = await fetch('/api/items');
                allItems = await response.json();
                renderItems(allItems);
            } catch (error) { console.error('Failed to load items:', error); }
        }
        function renderItems(items) {
            const container = document.getElementById('itemsList');
            if (items.length === 0) {
                container.innerHTML = `
                    <div class="empty-state">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                            <rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>
                            <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>
                        </svg>
                        <p>No clipboard items found</p>
                    </div>`;
                return;
            }
            container.innerHTML = items.map(item => {
                const typeClass = 'type-' + item.type;
                const time = new Date(item.timestamp * 1000).toLocaleString();
                let body = '';
                if (item.type === 'image') {
                    body = `<img class="thumb" src="/api/image?id=${item.id}" alt="image"/>`;
                    if (item.preview) {
                        body += `<div class="item-preview" style="margin-top:8px;">${escapeHtml(item.preview)}</div>`;
                    }
                } else {
                    body = `<div class="item-preview">${escapeHtml(item.preview)}</div>`;
                }
                return `
                    <div class="item-card">
                        <div class="item-header">
                            <span class="item-type ${typeClass}">${item.type}</span>
                            <span class="item-time">${time}</span>
                        </div>
                        ${body}
                        ${item.sourceApp ? `<div class="item-source">From: ${escapeHtml(item.sourceApp)}</div>` : ''}
                    </div>`;
            }).join('');
        }
        function escapeHtml(text) {
            const div = document.createElement('div');
            div.textContent = text;
            return div.innerHTML;
        }
        document.getElementById('searchInput').addEventListener('input', (e) => {
            const query = e.target.value.toLowerCase();
            if (query === '') { renderItems(allItems); }
            else {
                const filtered = allItems.filter(item =>
                    item.preview.toLowerCase().includes(query) ||
                    (item.sourceApp && item.sourceApp.toLowerCase().includes(query))
                );
                renderItems(filtered);
            }
        });
        loadItems();
        setInterval(loadItems, 5000);
        """
    }
    
    private func sendItemsJSON(connection: NWConnection) {
        database.fetchItems(limit: 100) { [weak self] items in
            guard let self = self else { return }
            
            let jsonItems = items.map { item -> [String: Any] in
                [
                    "id": item.id.uuidString,
                    "timestamp": item.timestamp.timeIntervalSince1970,
                    "type": item.type.rawValue,
                    "preview": item.preview(),
                    "sourceApp": item.sourceApp ?? ""
                ]
            }
            
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: jsonItems, options: [])
                let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"
                
                let response = """
                HTTP/1.1 200 OK
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

    private func sendImage(path: String, connection: NWConnection) {
        // 解析 URL 查询参数 id
        guard let comps = URLComponents(string: "http://localhost\(path)"),
              let idValue = comps.queryItems?.first(where: { $0.name == "id" })?.value,
              let uuid = UUID(uuidString: idValue) else {
            sendErrorResponse(connection: connection, status: 400, message: "Bad Request")
            return
        }
        database.fetchItems(limit: 200) { [weak self] items in
            guard let self = self else { return }
            guard let item = items.first(where: { $0.id == uuid }),
                  let data = item.imageData,
                  let image = NSImage(data: data),
                  let png = image.pngData() else {
                self.sendErrorResponse(connection: connection, status: 404, message: "Not Found")
                return
            }
            let header = """
            HTTP/1.1 200 OK
            Content-Type: image/png
            Content-Length: \(png.count)
            
            """
            let full = (header.data(using: .utf8) ?? Data()) + png
            connection.send(content: full, completion: .contentProcessed { _ in
                connection.cancel()
            })
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
        guard let data = response.data(using: .utf8) else {
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
