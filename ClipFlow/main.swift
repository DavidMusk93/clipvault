import Foundation
import AppKit

// LaunchAgent redirects stdout/stderr to files (full block buffering by default).
// Force line buffering so startup / backup logs appear promptly.
setlinebuf(stdout)
setlinebuf(stderr)

print("🚀 启动 ClipFlow 后台守护进程与 Web 服务 (Port: 8080)...")

let db = DatabaseManager()
// Plane A: disaster backup (sqlite3_backup + CAS snapshots)
let backup = CloudDocsBackupService.bootstrap(database: db)
// Plane B: multi-device live sync (op-log + shared CAS) — never whole-db replace
let sync = CloudDocsSyncService.bootstrap(database: db)
let monitor = ClipboardMonitor(database: db)
let webServer = WebServer(port: 8080, database: db, backup: backup, sync: sync)

monitor.startMonitoring()
webServer.start()

print("✅ ClipFlow Web 服务已成功运行：")
print("👉 本地 Web UI 访问地址: http://localhost:8080")
if let root = backup.backupRootURL {
    print("☁️  备份主目录: \(root.path)")
} else {
    print("⚠️  暂无可用备份目标（iCloud / Google Drive）；登录后自动生效")
}
sync.statusSnapshot { st in
    print("🔄 多机同步: host=\(st.hostId) enabled=\(st.enabled) root=\(st.syncRootPath ?? "nil")")
}
if let gd = CloudDocsBackupService.googleDriveMyDriveURL() {
    print("📂 Google Drive: \(gd.appendingPathComponent("Keepsake/backup").path)")
} else {
    print("ℹ️  Google Drive 未挂载 — 安装并登录 Desktop 后启用 gdrive 目标")
}

RunLoop.main.run()
