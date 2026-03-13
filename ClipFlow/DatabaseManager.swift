import Foundation
import DuckDB

enum DatabaseError: Error {
    case connectionFailed
    case statementFailed(String)
    case queryFailed(String)
    case encodingFailed
}

final class DatabaseManager: ObservableObject {
    private let dbPath: URL
    private let dbQueue = DispatchQueue(label: "com.clipflow.database", qos: .userInitiated)
    
    private var database: Database?
    private var connection: Connection?
    
    init() {
        let fileManager = FileManager.default
        let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            fileManager.temporaryDirectory.appendingPathComponent("com.clipflow.app")
        let appDir = appSupportDir.appendingPathComponent("ClipFlow")
        
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        
        dbPath = appDir.appendingPathComponent("clipflow.duckdb")
        
        initializeDatabase()
    }

    // 对外暴露数据库文件路径（用于 iCloud 备份）
    var dbFileURL: URL { dbPath }
    
    private func initializeDatabase() {
        do {
            database = try Database(store: .file(at: dbPath))
            connection = try database?.connect()
            try createTables()
            migrateFromJSON()
        } catch {
            print("Failed to initialize DuckDB: \(error)")
        }
    }
    
    private func createTables() throws {
        let createSQL = """
        CREATE TABLE IF NOT EXISTS clipboard_items (
            id VARCHAR PRIMARY KEY,
            timestamp DOUBLE NOT NULL,
            type VARCHAR NOT NULL,
            content_hash VARCHAR NOT NULL,
            text_content VARCHAR,
            image_data BLOB,
            file_urls VARCHAR,
            url VARCHAR,
            rtf_data BLOB,
            pdf_data BLOB,
            html_content VARCHAR,
            raw_data BLOB,
            source_app VARCHAR,
            ocr_text VARCHAR
        );
        
        CREATE INDEX IF NOT EXISTS idx_timestamp ON clipboard_items(timestamp);
        CREATE INDEX IF NOT EXISTS idx_content_hash ON clipboard_items(content_hash);
        """
        try connection?.execute(createSQL)
    }
    
    private func migrateFromJSON() {
        let fileManager = FileManager.default
        let itemsDir = dbPath.deletingLastPathComponent().appendingPathComponent("items")
        guard fileManager.fileExists(atPath: itemsDir.path) else { return }
        
        print("Migrating JSON items to DuckDB...")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        
        guard let files = try? fileManager.contentsOfDirectory(at: itemsDir, includingPropertiesForKeys: nil) else { return }
        
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let item = try? decoder.decode(ClipboardItem.self, from: data) {
                saveItemSync(item)
            }
            try? fileManager.removeItem(at: file) // 删除已迁移的文件
        }
        try? fileManager.removeItem(at: itemsDir) // 删除目录
        print("Migration complete.")
    }
    
    func saveItem(_ item: ClipboardItem, completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self else { completion?(false); return }
            let success = self.saveItemSync(item)
            DispatchQueue.main.async { completion?(success) }
        }
    }
    
    private func saveItemSync(_ item: ClipboardItem) -> Bool {
        do {
            let sql = """
            INSERT OR REPLACE INTO clipboard_items VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            let stmt = try connection?.prepareStatement(sql)
            
            let fileURLsStr = item.fileURLs?.map { $0.path }.joined(separator: "|")
            
            try stmt?.execute(
                item.id.uuidString,
                item.timestamp.timeIntervalSince1970,
                item.type.rawValue,
                item.contentHash,
                item.textContent,
                item.imageData,
                fileURLsStr,
                item.url?.absoluteString,
                item.rtfData,
                item.pdfData,
                item.htmlContent,
                item.rawData,
                item.sourceApp,
                item.ocrText
            )
            return true
        } catch {
            print("Failed to save item: \(error)")
            return false
        }
    }
    
    func fetchItems(limit: Int = 100, completion: @escaping ([ClipboardItem]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self else { completion([]); return }
            do {
                let result = try self.connection?.query("SELECT * FROM clipboard_items ORDER BY timestamp DESC LIMIT \(limit)")
                let items = self.parseResult(result)
                DispatchQueue.main.async { completion(items) }
            } catch {
                print("Fetch failed: \(error)")
                DispatchQueue.main.async { completion([]) }
            }
        }
    }
    
    func searchItems(query: String, limit: Int = 100, completion: @escaping ([ClipboardItem]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self else { completion([]); return }
            do {
                let sql = """
                SELECT * FROM clipboard_items 
                WHERE text_content ILIKE ? OR source_app ILIKE ? OR ocr_text ILIKE ?
                ORDER BY timestamp DESC LIMIT ?
                """
                let stmt = try self.connection?.prepareStatement(sql)
                let pattern = "%\(query)%"
                let result = try stmt?.query(pattern, pattern, pattern, limit)
                let items = self.parseResult(result)
                DispatchQueue.main.async { completion(items) }
            } catch {
                print("Search failed: \(error)")
                DispatchQueue.main.async { completion([]) }
            }
        }
    }
    
    func deleteItem(_ item: ClipboardItem, completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self else { completion?(false); return }
            do {
                try self.connection?.execute("DELETE FROM clipboard_items WHERE id = '\(item.id.uuidString)'")
                DispatchQueue.main.async { completion?(true) }
            } catch {
                print("Delete failed: \(error)")
                DispatchQueue.main.async { completion?(false) }
            }
        }
    }
    
    func clearAll(completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self else { completion?(false); return }
            do {
                try self.connection?.execute("DELETE FROM clipboard_items")
                DispatchQueue.main.async { completion?(true) }
            } catch {
                print("Clear failed: \(error)")
                DispatchQueue.main.async { completion?(false) }
            }
        }
    }
    
    private func parseResult(_ result: QueryResult?) -> [ClipboardItem] {
        guard let result = result else { return [] }
        var items: [ClipboardItem] = []
        
        for i in 0..<result.rowCount {
            // DuckDB result casting. Adjust types as needed based on library behavior.
            // Assuming result[col][row] returns correct Swift type or nil
            guard let idStr = result[0][i] as? String,
                  let id = UUID(uuidString: idStr),
                  let ts = result[1][i] as? Double,
                  let typeStr = result[2][i] as? String,
                  let type = ClipboardType(rawValue: typeStr),
                  let hash = result[3][i] as? String else { continue }
            
            let textContent = result[4][i] as? String
            let imageData = result[5][i] as? Data
            let fileURLsStr = result[6][i] as? String
            let fileURLs = fileURLsStr?.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
            let urlStr = result[7][i] as? String
            let url = urlStr != nil ? URL(string: urlStr!) : nil
            let rtfData = result[8][i] as? Data
            let pdfData = result[9][i] as? Data
            let htmlContent = result[10][i] as? String
            let rawData = result[11][i] as? Data
            let sourceApp = result[12][i] as? String
            let ocrText = result[13][i] as? String
            
            let item = ClipboardItem(
                id: id,
                timestamp: Date(timeIntervalSince1970: ts),
                type: type,
                contentHash: hash,
                textContent: textContent,
                imageData: imageData,
                fileURLs: fileURLs,
                url: url,
                rtfData: rtfData,
                pdfData: pdfData,
                htmlContent: htmlContent,
                rawData: rawData,
                ocrText: ocrText,
                sourceApp: sourceApp
            )
            items.append(item)
        }
        return items
    }
}
