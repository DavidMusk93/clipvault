import Foundation

enum DatabaseError: Error {
    case connectionFailed
    case statementFailed(String)
    case queryFailed(String)
    case encodingFailed
}

class DatabaseManager: ObservableObject {
    private let dbPath: URL
    private let dbQueue = DispatchQueue(label: "com.clipflow.database", qos: .userInitiated)
    
    private var connection: Any?
    
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
        createTables()
    }
    
    private func createTables() {
        let fileManager = FileManager.default
        let dbExists = fileManager.fileExists(atPath: dbPath.path)
        
        if !dbExists {
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
                source_app VARCHAR
            );
            
            CREATE INDEX IF NOT EXISTS idx_timestamp ON clipboard_items(timestamp);
            CREATE INDEX IF NOT EXISTS idx_content_hash ON clipboard_items(content_hash);
            """
            
            executeSQL(createSQL)
        }
    }
    
    private func executeSQL(_ sql: String) {
        let task = Process()
        let pipe = Pipe()
        
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["bash", "-c", """
        if command -v duckdb &> /dev/null; then
            duckdb '\(dbPath.path)' << 'SQL_EOF'
            \(sql)
            SQL_EOF
        else
            echo "DuckDB not installed, using file-based storage"
        fi
        """]
        
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            print("Failed to execute SQL: \(error)")
        }
    }
    
    func saveItem(_ item: ClipboardItem, completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            
            let success = self.saveItemToFile(item)
            DispatchQueue.main.async { completion?(success) }
        }
    }
    
    private func saveItemToFile(_ item: ClipboardItem) -> Bool {
        let fileManager = FileManager.default
        let itemsDir = dbPath.deletingLastPathComponent().appendingPathComponent("items")
        
        try? fileManager.createDirectory(at: itemsDir, withIntermediateDirectories: true)
        
        let itemFile = itemsDir.appendingPathComponent("\(item.id.uuidString).json")
        
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(item)
            try data.write(to: itemFile)
            return true
        } catch {
            print("Failed to save item: \(error)")
            return false
        }
    }
    
    func fetchItems(limit: Int = 100, completion: @escaping ([ClipboardItem]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            
            let items = self.loadItemsFromFile(limit: limit)
            DispatchQueue.main.async { completion(items) }
        }
    }
    
    private func loadItemsFromFile(limit: Int) -> [ClipboardItem] {
        let fileManager = FileManager.default
        let itemsDir = dbPath.deletingLastPathComponent().appendingPathComponent("items")
        
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: itemsDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        let sortedFiles = fileURLs.sorted { url1, url2 in
            let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            return date1 > date2
        }
        
        var items: [ClipboardItem] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        
        for (index, fileURL) in sortedFiles.enumerated() {
            if index >= limit { break }
            
            if let data = try? Data(contentsOf: fileURL),
               let item = try? decoder.decode(ClipboardItem.self, from: data) {
                items.append(item)
            }
        }
        
        return items
    }
    
    func searchItems(query: String, limit: Int = 100, completion: @escaping ([ClipboardItem]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            
            let allItems = self.loadItemsFromFile(limit: limit * 2)
            let filtered = allItems.filter { item in
                let q = query.lowercased()
                return item.preview().lowercased().contains(q) ||
                    (item.ocrText?.lowercased().contains(q) ?? false) ||
                    (item.sourceApp?.lowercased().contains(q) ?? false)
            }
            
            DispatchQueue.main.async { completion(Array(filtered.prefix(limit))) }
        }
    }
    
    func deleteItem(_ item: ClipboardItem, completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            
            let fileManager = FileManager.default
            let itemsDir = self.dbPath.deletingLastPathComponent().appendingPathComponent("items")
            let itemFile = itemsDir.appendingPathComponent("\(item.id.uuidString).json")
            
            let success = (try? fileManager.removeItem(at: itemFile)) != nil
            DispatchQueue.main.async { completion?(success) }
        }
    }
    
    func clearAll(completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            
            let fileManager = FileManager.default
            let itemsDir = self.dbPath.deletingLastPathComponent().appendingPathComponent("items")
            
            let success = (try? fileManager.removeItem(at: itemsDir)) != nil
            try? fileManager.createDirectory(at: itemsDir, withIntermediateDirectories: true)
            
            DispatchQueue.main.async { completion?(success) }
        }
    }
}
