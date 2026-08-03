import Foundation
import AppKit

print("🚀 启动 ClipFlow 后台守护进程与 Web 服务 (Port: 8080)...")

let db = DatabaseManager()
// CloudDocs backup first — shares same DatabaseManager (sqlite3_backup online)
let backup = CloudDocsBackupService.bootstrap(database: db)
let monitor = ClipboardMonitor(database: db)
let webServer = WebServer(port: 8080, database: db, backup: backup)

monitor.startMonitoring()
webServer.start()

print("✅ ClipFlow Web 服务已成功运行：")
print("👉 本地 Web UI 访问地址: http://localhost:8080")
if let root = backup.backupRootURL {
    print("☁️  iCloud Drive 备份目录: \(root.path)")
} else {
    print("⚠️  未检测到 iCloud Drive (CloudDocs)；备份将在可用后自动写入")
}

RunLoop.main.run()
