import Foundation
import SQLite3

enum DatabaseError: Error {
    case connectionFailed
    case statementFailed(String)
    case queryFailed(String)
    case encodingFailed
}

class DatabaseManager: ObservableObject {
    private var db: OpaquePointer?
    private let dbPath: URL
    
    private let dbQueue = DispatchQueue(label: "com.clipflow.database", qos: .userInitiated)
    
    init() {
        let fileManager = FileManager.default
        let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupportDir.appendingPathComponent("ClipFlow")
        
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        
        dbPath = appDir.appendingPathComponent("clipflow.duckdb")
        
        initializeDatabase()
    }

    // 对外暴露数据库文件路径（用于 iCloud 备份）
    var dbFileURL: URL { dbPath }
    
    private func initializeDatabase() {
        if sqlite3_open(dbPath.path, &db) != SQLITE_OK {
            print("Failed to open database")
            return
        }
        
        createTables()
    }
    
    private func createTables() {
        let createTableSQL = """
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
            source_app TEXT
        );
        
        CREATE INDEX IF NOT EXISTS idx_timestamp ON clipboard_items(timestamp);
        CREATE INDEX IF NOT EXISTS idx_content_hash ON clipboard_items(content_hash);
        """
        
        var errorMessage: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, createTableSQL, nil, nil, &errorMessage) != SQLITE_OK {
            if let error = errorMessage {
                print("Error creating table: \(String(cString: error))")
                sqlite3_free(error)
            }
        }
    }
    
    func saveItem(_ item: ClipboardItem, completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self else {
                completion?(false)
                return
            }
            
            let insertSQL = """
            INSERT OR REPLACE INTO clipboard_items 
            (id, timestamp, type, content_hash, text_content, image_data, file_urls, url, rtf_data, pdf_data, html_content, raw_data, source_app)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(self.db, insertSQL, -1, &statement, nil) != SQLITE_OK {
                print("Failed to prepare statement")
                completion?(false)
                return
            }
            
            let idString = item.id.uuidString
            sqlite3_bind_text(statement, 1, (idString as NSString).utf8String, -1, nil)
            sqlite3_bind_double(statement, 2, item.timestamp.timeIntervalSince1970)
            sqlite3_bind_text(statement, 3, (item.type.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 4, (item.contentHash as NSString).utf8String, -1, nil)
            
            if let textContent = item.textContent {
                sqlite3_bind_text(statement, 5, (textContent as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(statement, 5)
            }
            
            if let imageData = item.imageData {
                imageData.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, 6, buffer.baseAddress, Int32(imageData.count), nil)
                }
            } else {
                sqlite3_bind_null(statement, 6)
            }
            
            if let fileURLs = item.fileURLs {
                let urlsString = fileURLs.map { $0.path }.joined(separator: "|")
                sqlite3_bind_text(statement, 7, (urlsString as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(statement, 7)
            }
            
            if let url = item.url {
                sqlite3_bind_text(statement, 8, (url.absoluteString as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(statement, 8)
            }
            
            if let rtfData = item.rtfData {
                rtfData.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, 9, buffer.baseAddress, Int32(rtfData.count), nil)
                }
            } else {
                sqlite3_bind_null(statement, 9)
            }
            
            if let pdfData = item.pdfData {
                pdfData.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, 10, buffer.baseAddress, Int32(pdfData.count), nil)
                }
            } else {
                sqlite3_bind_null(statement, 10)
            }
            
            if let htmlContent = item.htmlContent {
                sqlite3_bind_text(statement, 11, (htmlContent as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(statement, 11)
            }
            
            if let rawData = item.rawData {
                rawData.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, 12, buffer.baseAddress, Int32(rawData.count), nil)
                }
            } else {
                sqlite3_bind_null(statement, 12)
            }
            
            if let sourceApp = item.sourceApp {
                sqlite3_bind_text(statement, 13, (sourceApp as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(statement, 13)
            }
            
            let success = sqlite3_step(statement) == SQLITE_DONE
            sqlite3_finalize(statement)
            
            DispatchQueue.main.async {
                completion?(success)
            }
        }
    }
    
    func fetchItems(limit: Int = 100, completion: @escaping ([ClipboardItem]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self else {
                completion([])
                return
            }
            
            var items: [ClipboardItem] = []
            
            let querySQL = "SELECT * FROM clipboard_items ORDER BY timestamp DESC LIMIT ?;"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.db, querySQL, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int(statement, 1, Int32(limit))
                
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let item = self.createItem(from: statement) {
                        items.append(item)
                    }
                }
                
                sqlite3_finalize(statement)
            }
            
            DispatchQueue.main.async {
                completion(items)
            }
        }
    }
    
    func searchItems(query: String, limit: Int = 100, completion: @escaping ([ClipboardItem]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self else {
                completion([])
                return
            }
            
            var items: [ClipboardItem] = []
            
            let searchPattern = "%\(query)%"
            let querySQL = """
            SELECT * FROM clipboard_items 
            WHERE text_content LIKE ? OR source_app LIKE ? 
            ORDER BY timestamp DESC LIMIT ?;
            """
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.db, querySQL, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (searchPattern as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 2, (searchPattern as NSString).utf8String, -1, nil)
                sqlite3_bind_int(statement, 3, Int32(limit))
                
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let item = self.createItem(from: statement) {
                        items.append(item)
                    }
                }
                
                sqlite3_finalize(statement)
            }
            
            DispatchQueue.main.async {
                completion(items)
            }
        }
    }
    
    func deleteItem(_ item: ClipboardItem, completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self else {
                completion?(false)
                return
            }
            
            let deleteSQL = "DELETE FROM clipboard_items WHERE id = ?;"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.db, deleteSQL, -1, &statement, nil) == SQLITE_OK {
                let idString = item.id.uuidString
                sqlite3_bind_text(statement, 1, (idString as NSString).utf8String, -1, nil)
                
                let success = sqlite3_step(statement) == SQLITE_DONE
                sqlite3_finalize(statement)
                
                DispatchQueue.main.async {
                    completion?(success)
                }
            } else {
                DispatchQueue.main.async {
                    completion?(false)
                }
            }
        }
    }
    
    func clearAll(completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self else {
                completion?(false)
                return
            }
            
            let deleteSQL = "DELETE FROM clipboard_items;"
            var errorMessage: UnsafeMutablePointer<Int8>?
            
            let success = sqlite3_exec(self.db, deleteSQL, nil, nil, &errorMessage) == SQLITE_OK
            
            if let error = errorMessage {
                print("Error clearing database: \(String(cString: error))")
                sqlite3_free(error)
            }
            
            DispatchQueue.main.async {
                completion?(success)
            }
        }
    }
    
    private func createItem(from statement: OpaquePointer?) -> ClipboardItem? {
        guard let statement = statement else { return nil }
        
        guard let idCString = sqlite3_column_text(statement, 0),
              let id = UUID(uuidString: String(cString: idCString)) else {
            return nil
        }
        
        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        
        guard let typeCString = sqlite3_column_text(statement, 2),
              let type = ClipboardType(rawValue: String(cString: typeCString)) else {
            return nil
        }
        
        guard let hashCString = sqlite3_column_text(statement, 3) else {
            return nil
        }
        let contentHash = String(cString: hashCString)
        
        var textContent: String?
        if let textCString = sqlite3_column_text(statement, 4) {
            textContent = String(cString: textCString)
        }
        
        var imageData: Data?
        if let imageBlob = sqlite3_column_blob(statement, 5) {
            let imageSize = sqlite3_column_bytes(statement, 5)
            imageData = Data(bytes: imageBlob, count: Int(imageSize))
        }
        
        var fileURLs: [URL]?
        if let urlsCString = sqlite3_column_text(statement, 6) {
            let urlsString = String(cString: urlsCString)
            fileURLs = urlsString.components(separatedBy: "|").map { URL(fileURLWithPath: $0) }
        }
        
        var url: URL?
        if let urlCString = sqlite3_column_text(statement, 7) {
            url = URL(string: String(cString: urlCString))
        }
        
        var rtfData: Data?
        if let rtfBlob = sqlite3_column_blob(statement, 8) {
            let rtfSize = sqlite3_column_bytes(statement, 8)
            rtfData = Data(bytes: rtfBlob, count: Int(rtfSize))
        }
        
        var pdfData: Data?
        if let pdfBlob = sqlite3_column_blob(statement, 9) {
            let pdfSize = sqlite3_column_bytes(statement, 9)
            pdfData = Data(bytes: pdfBlob, count: Int(pdfSize))
        }
        
        var htmlContent: String?
        if let htmlCString = sqlite3_column_text(statement, 10) {
            htmlContent = String(cString: htmlCString)
        }
        
        var rawData: Data?
        if let rawBlob = sqlite3_column_blob(statement, 11) {
            let rawSize = sqlite3_column_bytes(statement, 11)
            rawData = Data(bytes: rawBlob, count: Int(rawSize))
        }
        
        var sourceApp: String?
        if let sourceAppCString = sqlite3_column_text(statement, 12) {
            sourceApp = String(cString: sourceAppCString)
        }
        
        return ClipboardItem(
            id: id,
            timestamp: timestamp,
            type: type,
            contentHash: contentHash,
            textContent: textContent,
            imageData: imageData,
            fileURLs: fileURLs,
            url: url,
            rtfData: rtfData,
            pdfData: pdfData,
            htmlContent: htmlContent,
            rawData: rawData,
            sourceApp: sourceApp
        )
    }
    
    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }
}
