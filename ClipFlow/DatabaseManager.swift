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
        // Changed to Documents for easier access/debug and avoiding potential sandbox issues
        let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ??
            fileManager.temporaryDirectory.appendingPathComponent("com.clipflow.app")
        let appDir = docsDir.appendingPathComponent("ClipFlow")
        
        try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        
        dbPath = appDir.appendingPathComponent("clipflow.duckdb")
        
        initializeDatabase()
    }

    // 对外暴露数据库文件路径（用于 iCloud 备份）
    var dbFileURL: URL { dbPath }
    
    private func initializeDatabase() {
        do {
            LogManager.shared.write("[Database] Initializing DuckDB at \(dbPath.path)")
            database = try Database(store: .file(at: dbPath))
            connection = try database?.connect()
            try createTables()
            migrateFromJSON()
            LogManager.shared.write("[Database] Initialization success")
        } catch {
            print("Failed to initialize DuckDB: \(error)")
            LogManager.shared.write("[Database] Failed to initialize: \(error)")
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
                _ = saveItemSync(item)
            }
            try? fileManager.removeItem(at: file)
        }
        try? fileManager.removeItem(at: itemsDir)
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
        guard let connection = connection else { return false }
        do {
            let sql = """
            INSERT OR REPLACE INTO clipboard_items 
            (id, timestamp, type, content_hash, text_content, image_data, file_urls, url, rtf_data, pdf_data, html_content, raw_data, source_app, ocr_text)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            let stmt = try PreparedStatement(connection: connection, query: sql)
            
            let fileURLsStr = item.fileURLs?.map { $0.path }.joined(separator: "|")
            
            try stmt.bind(item.id.uuidString, at: 1)
            try stmt.bind(item.timestamp.timeIntervalSince1970, at: 2)
            try stmt.bind(item.type.rawValue, at: 3)
            try stmt.bind(item.contentHash, at: 4)
            try stmt.bind(item.textContent, at: 5)
            try stmt.bind(item.imageData, at: 6)
            try stmt.bind(fileURLsStr, at: 7)
            try stmt.bind(item.url?.absoluteString, at: 8)
            try stmt.bind(item.rtfData, at: 9)
            try stmt.bind(item.pdfData, at: 10)
            try stmt.bind(item.htmlContent, at: 11)
            try stmt.bind(item.rawData, at: 12)
            try stmt.bind(item.sourceApp, at: 13)
            try stmt.bind(item.ocrText, at: 14)
            
            _ = try stmt.execute()
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
            guard let self = self, let connection = self.connection else { completion([]); return }
            do {
                let sql = """
                SELECT * FROM clipboard_items 
                WHERE text_content ILIKE ? OR source_app ILIKE ? OR ocr_text ILIKE ?
                ORDER BY timestamp DESC LIMIT ?
                """
                let stmt = try PreparedStatement(connection: connection, query: sql)
                let pattern = "%\(query)%"
                try stmt.bind(pattern, at: 1)
                try stmt.bind(pattern, at: 2)
                try stmt.bind(pattern, at: 3)
                try stmt.bind(Int64(limit), at: 4)
                
                let result = try stmt.execute()
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
    
    // swiftlint:disable function_body_length
    private func parseResult(_ result: ResultSet?) -> [ClipboardItem] {
        guard let result = result else { return [] }
        var items: [ClipboardItem] = []
        let rowCount = result.rowCount
        
        let idCol = result[0].cast(to: String.self)
        let tsCol = result[1].cast(to: Double.self)
        let typeCol = result[2].cast(to: String.self)
        let hashCol = result[3].cast(to: String.self)
        let textCol = result[4].cast(to: String.self)
        let imageCol = result[5].cast(to: Data.self)
        let filesCol = result[6].cast(to: String.self)
        let urlCol = result[7].cast(to: String.self)
        let rtfCol = result[8].cast(to: Data.self)
        let pdfCol = result[9].cast(to: Data.self)
        let htmlCol = result[10].cast(to: String.self)
        let rawCol = result[11].cast(to: Data.self)
        let appCol = result[12].cast(to: String.self)
        let ocrCol = result[13].cast(to: String.self)
        
        for index in 0..<rowCount {
            guard let idStr = idCol[index],
                  let id = UUID(uuidString: idStr),
                  let ts = tsCol[index],
                  let typeStr = typeCol[index],
                  let type = ClipboardType(rawValue: typeStr),
                  let hash = hashCol[index] else { continue }
            
            let textContent = textCol[index]
            let imageData = imageCol[index]
            let fileURLsStr = filesCol[index]
            let fileURLs = fileURLsStr?.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
            let urlStr = urlCol[index]
            let url = urlStr.flatMap { URL(string: $0) }
            let rtfData = rtfCol[index]
            let pdfData = pdfCol[index]
            let htmlContent = htmlCol[index]
            let rawData = rawCol[index]
            let sourceApp = appCol[index]
            let ocrText = ocrCol[index]
            
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
    // swiftlint:enable function_body_length
}