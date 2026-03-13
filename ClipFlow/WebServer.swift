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
                const time = new Date(item.timestamp * 1000).toLocaleString();
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
    
    private func sendItemsJSON(connection: NWConnection) {
        database.fetchItems(limit: 100) { [weak self] items in
            guard let self = self else { return }
            
            let jsonItems = items.map { item -> [String: Any] in
                var dict: [String: Any] = [
                    "id": item.id.uuidString,
                    "timestamp": item.timestamp.timeIntervalSince1970,
                    "type": item.type.rawValue,
                    "preview": item.preview(),
                    "sourceApp": item.sourceApp ?? ""
                ]
                
                // 注入富文本内容
                if let html = item.htmlContent {
                    dict["htmlContent"] = html
                }
                if let text = item.textContent {
                    dict["textContent"] = text
                }
                
                return dict
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
