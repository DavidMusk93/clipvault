import Foundation
import SQLite3

enum DatabaseError: Error {
    case connectionFailed
    case statementFailed(String)
    case queryFailed(String)
}

final class DatabaseManager: ObservableObject {
    private let dbPath: URL
    private let dbQueue = DispatchQueue(label: "com.clipflow.database", qos: .userInitiated)
    private var db: OpaquePointer?
    
    init() {
        let fileManager = FileManager.default
        let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ??
            fileManager.temporaryDirectory.appendingPathComponent("com.clipflow.app")
        let appDir = docsDir.appendingPathComponent("ClipFlow")
        
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        dbPath = appDir.appendingPathComponent("clipflow.db")
        
        initializeDatabase()
    }

    var dbFileURL: URL { dbPath }
    
    private func initializeDatabase() {
        if sqlite3_open(dbPath.path, &db) == SQLITE_OK {
            createTables()
        } else {
            print("Failed to open SQLite database at \(dbPath.path)")
        }
    }
    
    private func createTables() {
        let createSQL = """
        CREATE TABLE IF NOT EXISTS clipboard_items (
            id TEXT PRIMARY KEY,
            timestamp REAL NOT NULL,
            type TEXT NOT NULL,
            content_hash TEXT NOT NULL,
            text_content TEXT,
            image_data BLOB,
            file_urls TEXT,
            url TEXT,
            rtf_data BLOB,
            pdf_data BLOB,
            html_content TEXT,
            raw_data BLOB,
            source_app TEXT,
            ocr_text TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_timestamp ON clipboard_items(timestamp);
        """
        sqlite3_exec(db, createSQL, nil, nil, nil)
    }
    
    func saveItem(_ item: ClipboardItem, completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { completion?(false); return }
            
            let sql = """
            INSERT OR REPLACE INTO clipboard_items 
            (id, timestamp, type, content_hash, text_content, image_data, file_urls, url, rtf_data, pdf_data, html_content, raw_data, source_app, ocr_text)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                
                sqlite3_bind_text(stmt, 1, (item.id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 2, item.timestamp.timeIntervalSince1970)
                sqlite3_bind_text(stmt, 3, (item.type.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, (item.contentHash as NSString).utf8String, -1, SQLITE_TRANSIENT)
                
                if let text = item.textContent {
                    sqlite3_bind_text(stmt, 5, (text as NSString).utf8String, -1, SQLITE_TRANSIENT)
                } else { sqlite3_bind_null(stmt, 5) }
                
                if let imgData = item.imageData {
                    imgData.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(stmt, 6, ptr.baseAddress, Int32(imgData.count), SQLITE_TRANSIENT)
                    }
                } else { sqlite3_bind_null(stmt, 6) }
                
                let fileURLsStr = item.fileURLs?.map { $0.path }.joined(separator: "|")
                if let fUrls = fileURLsStr {
                    sqlite3_bind_text(stmt, 7, (fUrls as NSString).utf8String, -1, SQLITE_TRANSIENT)
                } else { sqlite3_bind_null(stmt, 7) }
                
                if let urlStr = item.url?.absoluteString {
                    sqlite3_bind_text(stmt, 8, (urlStr as NSString).utf8String, -1, SQLITE_TRANSIENT)
                } else { sqlite3_bind_null(stmt, 8) }
                
                sqlite3_bind_null(stmt, 9)
                sqlite3_bind_null(stmt, 10)
                
                if let html = item.htmlContent {
                    sqlite3_bind_text(stmt, 11, (html as NSString).utf8String, -1, SQLITE_TRANSIENT)
                } else { sqlite3_bind_null(stmt, 11) }
                
                sqlite3_bind_null(stmt, 12)
                
                if let srcApp = item.sourceApp {
                    sqlite3_bind_text(stmt, 13, (srcApp as NSString).utf8String, -1, SQLITE_TRANSIENT)
                } else { sqlite3_bind_null(stmt, 13) }
                
                if let ocr = item.ocrText {
                    sqlite3_bind_text(stmt, 14, (ocr as NSString).utf8String, -1, SQLITE_TRANSIENT)
                } else { sqlite3_bind_null(stmt, 14) }
                
                let stepRes = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                
                let success = (stepRes == SQLITE_DONE)
                DispatchQueue.main.async { completion?(success) }
            } else {
                DispatchQueue.main.async { completion?(false) }
            }
        }
    }
    
    func fetchItems(limit: Int = 100, completion: @escaping ([ClipboardItem]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { completion([]); return }
            
            var items: [ClipboardItem] = []
            let sql = "SELECT id, timestamp, type, content_hash, text_content, image_data, file_urls, url, html_content, source_app, ocr_text FROM clipboard_items ORDER BY timestamp DESC LIMIT ?;"
            
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int(stmt, 1, Int32(limit))
                
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                          let uuid = UUID(uuidString: idStr),
                          let typeStr = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
                          let hash = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }) else {
                        continue
                    }
                    
                    let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
                    let textContent = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                    
                    var imageData: Data? = nil
                    if let blobPtr = sqlite3_column_blob(stmt, 5) {
                        let blobSize = sqlite3_column_bytes(stmt, 5)
                        imageData = Data(bytes: blobPtr, count: Int(blobSize))
                    }
                    
                    let htmlContent = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
                    let sourceApp = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
                    let ocrText = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
                    
                    let item = ClipboardItem(
                        id: uuid,
                        timestamp: timestamp,
                        type: ClipboardType(rawValue: typeStr) ?? .text,
                        contentHash: hash,
                        textContent: textContent,
                        imageData: imageData,
                        htmlContent: htmlContent,
                        ocrText: ocrText,
                        sourceApp: sourceApp
                    )
                    items.append(item)
                }
                sqlite3_finalize(stmt)
            }
            
            DispatchQueue.main.async { completion(items) }
        }
    }
    
    func deleteItem(_ item: ClipboardItem, completion: ((Bool) -> Void)? = nil) {
        deleteItem(id: item.id, completion: completion)
    }

    func deleteItem(id: UUID, completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { completion?(false); return }
            
            let sql = "DELETE FROM clipboard_items WHERE id = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(stmt, 1, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                let stepRes = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                
                let success = (stepRes == SQLITE_DONE)
                DispatchQueue.main.async { completion?(success) }
            } else {
                DispatchQueue.main.async { completion?(false) }
            }
        }
    }

    func searchItems(query: String, limit: Int = 100, completion: @escaping ([ClipboardItem]) -> Void) {
        fetchItems(limit: limit) { items in
            let filtered = items.filter { item in
                let textMatch = (item.textContent ?? "").localizedCaseInsensitiveContains(query)
                let ocrMatch = (item.ocrText ?? "").localizedCaseInsensitiveContains(query)
                let appMatch = (item.sourceApp ?? "").localizedCaseInsensitiveContains(query)
                return textMatch || ocrMatch || appMatch
            }
            completion(filtered)
        }
    }

    func fetchImageData(id: UUID, completion: @escaping (Data?) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { completion(nil); return }
            let sql = "SELECT image_data FROM clipboard_items WHERE id = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(stmt, 1, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                
                if sqlite3_step(stmt) == SQLITE_ROW {
                    if let blobPtr = sqlite3_column_blob(stmt, 0) {
                        let size = sqlite3_column_bytes(stmt, 0)
                        if size > 0 {
                            let data = Data(bytes: blobPtr, count: Int(size))
                            sqlite3_finalize(stmt)
                            DispatchQueue.main.async { completion(data) }
                            return
                        }
                    }
                }
                sqlite3_finalize(stmt)
            }
            DispatchQueue.main.async { completion(nil) }
        }
    }

    func clearAll(completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { completion?(false); return }
            let sql = "DELETE FROM clipboard_items;"
            let res = sqlite3_exec(db, sql, nil, nil, nil)
            DispatchQueue.main.async { completion?(res == SQLITE_OK) }
        }
    }
    
    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }
}