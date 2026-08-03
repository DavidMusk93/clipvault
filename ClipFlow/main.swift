import Foundation
import AppKit

print("🚀 启动 ClipFlow 后台守护进程与 Web 服务 (Port: 8080)...")

let db = DatabaseManager()
let monitor = ClipboardMonitor(database: db)
let webServer = WebServer(port: 8080, database: db)

monitor.startMonitoring()
webServer.start()

print("✅ ClipFlow Web 服务已成功运行：")
print("👉 本地 Web UI 访问地址: http://localhost:8080")

RunLoop.main.run()
