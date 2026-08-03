import Foundation
import CloudKit

class iCloudSyncManager {
    static let shared = iCloudSyncManager()
    
    private let kvs = NSUbiquitousKeyValueStore.default
    private let databaseManager: DatabaseManager
    
    init(databaseManager: DatabaseManager = DatabaseManager()) {
        self.databaseManager = databaseManager
        setupObserver()
    }
    
    func setupObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(iCloudStoreDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs
        )
        kvs.synchronize()
    }
    
    func syncItemToCloud(_ item: ClipboardItem) {
        guard let text = item.textContent ?? item.ocrText else { return }
        let key = "clip_\(item.id.uuidString)"
        let payload: [String: Any] = [
            "id": item.id.uuidString,
            "timestamp": item.timestamp.timeIntervalSince1970,
            "text": text,
            "type": item.type.rawValue,
            "html": item.htmlContent ?? ""
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []) {
            kvs.set(data, forKey: key)
            kvs.synchronize()
        }
    }
    
    @objc private func iCloudStoreDidChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let changeReason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int else { return }
        
        print("iCloud store changed with reason: \(changeReason)")
        let keys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
        for key in keys where key.hasPrefix("clip_") {
            if let data = kvs.data(forKey: key),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String,
               let typeStr = json["type"] as? String,
               let uuidStr = json["id"] as? String,
               let uuid = UUID(uuidString: uuidStr) {
                
                let item = ClipboardItem(
                    id: uuid,
                    timestamp: Date(),
                    type: ClipboardType(rawValue: typeStr) ?? .text,
                    contentHash: text.hashValue.description,
                    textContent: text,
                    htmlContent: json["html"] as? String
                )
                databaseManager.saveItem(item)
            }
        }
    }
}
