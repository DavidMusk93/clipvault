import Foundation

/// Pluggable backup destination (folder-backed: iCloud Drive, Google Drive, custom path).
/// Artifact is produced once (sqlite3_backup + CAS blobs), then fan-out to each enabled root.
struct BackupDestinationConfig: Codable, Equatable, Identifiable {
    var id: String
    /// `icloud` | `gdrive` | `quark` | `folder`
    var type: String
    var enabled: Bool
    var label: String?
    /// Absolute path when type == folder (or override for quark staging)
    var path: String?

    static let icloudDefault = BackupDestinationConfig(
        id: "icloud", type: "icloud", enabled: true, label: "iCloud Drive", path: nil
    )
    static let gdriveDefault = BackupDestinationConfig(
        id: "gdrive", type: "gdrive", enabled: true, label: "Google Drive", path: nil
    )
    /// Quark Netdisk: local staging folder for Quark client backup/sync.
    /// Default **off** until user installs Quark and enables the destination.
    static let quarkDefault = BackupDestinationConfig(
        id: "quark", type: "quark", enabled: false, label: "夸克网盘", path: nil
    )

    static var defaultList: [BackupDestinationConfig] {
        [.icloudDefault, .gdriveDefault, .quarkDefault]
    }
}

struct BackupDestinationStatus: Codable, Equatable {
    var id: String
    var type: String
    var label: String
    var enabled: Bool
    var available: Bool
    var rootPath: String?
    var lastSuccessAt: String?
    var lastSuccessUnix: Double?
    var lastError: String?
    var lastPhase: String?
    var hint: String?
}

enum BackupDestinationResolver {
    private static let fm = FileManager.default

    static func cloudDocsURL() -> URL? {
        let url = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return url.standardizedFileURL
    }

    /// Google Drive for Desktop mount: `~/Library/CloudStorage/GoogleDrive-*/My Drive`
    static func googleDriveMyDriveURL() -> URL? {
        let cloudStorage = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: cloudStorage,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let driveRoots = entries.filter { $0.lastPathComponent.hasPrefix("GoogleDrive-") }
        // Prefer newest / first available with a My Drive folder
        let myDriveNames = [
            "My Drive",
            "我的云端硬盘",
            "Mi unidad",
            "Mon Drive",
            "Meine Ablage",
            "Il mio Drive",
            "Meu Drive",
            "マイドライブ"
        ]
        for root in driveRoots.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            for name in myDriveNames {
                let candidate = root.appendingPathComponent(name, isDirectory: true)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                    return candidate.standardizedFileURL
                }
            }
            // Some installs expose files directly under GoogleDrive-*
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue {
                return root.standardizedFileURL
            }
        }
        return nil
    }

    /// Prefer configured path, else well-known Quark staging / sync folders.
    /// Quark Desktop does not expose a File Provider mount like Google Drive;
    /// it can **backup a local folder**. We write to a dedicated staging root that
    /// the user adds once under 夸克 → 备份 / 上传位置.
    static func quarkStagingURL(configuredPath: String? = nil) -> URL? {
        if let p = configuredPath?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url.standardizedFileURL
        }
        // Prefer existing user-created sync roots (if Quark already backs them up).
        let home = fm.homeDirectoryForCurrentUser
        let candidates: [URL] = [
            home.appendingPathComponent("夸克网盘", isDirectory: true),
            home.appendingPathComponent("QuarkCloudDrive", isDirectory: true),
            home.appendingPathComponent("QuarkNetDisk", isDirectory: true),
            home.appendingPathComponent("Documents/夸克网盘", isDirectory: true),
            home.appendingPathComponent("Documents/Quark", isDirectory: true),
        ]
        for c in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: c.path, isDirectory: &isDir), isDir.boolValue {
                return c.appendingPathComponent("ClipVault/backup", isDirectory: true)
            }
        }
        // Default staging (always creatable; user maps it in Quark client).
        let staging = home
            .appendingPathComponent("ClipVault-Backups/Quark/backup", isDirectory: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging.standardizedFileURL
    }

    /// True if Quark Desktop (or legacy installer) appears installed.
    static func quarkAppInstalled() -> Bool {
        let apps = [
            "/Applications/Quark.app",
            "/Applications/夸克网盘.app",
            "/Applications/夸克.app",
        ]
        return apps.contains { fm.fileExists(atPath: $0) }
    }

    /// Resolve backup root for a destination config.
    static func backupRoot(for dest: BackupDestinationConfig) -> URL? {
        switch dest.type {
        case "icloud":
            return cloudDocsURL()?.appendingPathComponent("ClipFlow/backup", isDirectory: true)
        case "gdrive":
            // Brand folder ClipVault; keep reading legacy Keepsake/backup.
            guard let my = googleDriveMyDriveURL() else { return nil }
            let preferred = my.appendingPathComponent("ClipVault/backup", isDirectory: true)
            if FileManager.default.fileExists(atPath: preferred.path) { return preferred }
            let legacy = my.appendingPathComponent("Keepsake/backup", isDirectory: true)
            if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
            return preferred
        case "quark":
            return quarkStagingURL(configuredPath: dest.path)
        case "folder":
            guard let p = dest.path, !p.isEmpty else { return nil }
            return URL(fileURLWithPath: p, isDirectory: true).standardizedFileURL
        default:
            return nil
        }
    }

    static func displayLabel(_ dest: BackupDestinationConfig) -> String {
        if let l = dest.label, !l.isEmpty { return l }
        switch dest.type {
        case "icloud": return "iCloud Drive"
        case "gdrive": return "Google Drive"
        case "quark": return "夸克网盘"
        case "folder": return dest.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Folder"
        default: return dest.id
        }
    }

    /// Whether ClipVault can **meaningfully** use this destination right now.
    /// Quark is special: a local staging folder can always be created, but that is
    /// **not** cloud readiness — require Quark.app so UI does not show a false green.
    static func isDestinationReady(_ dest: BackupDestinationConfig) -> Bool {
        guard let root = backupRoot(for: dest) else { return false }
        _ = root
        switch dest.type {
        case "quark":
            return quarkAppInstalled()
        default:
            return true
        }
    }

    static func availabilityHint(for dest: BackupDestinationConfig) -> String? {
        if dest.type == "gdrive", googleDriveMyDriveURL() == nil {
            return "请安装并登录 Google Drive for Desktop，登录后出现 CloudStorage/GoogleDrive-* 即可"
        }
        if dest.type == "icloud", cloudDocsURL() == nil {
            return "请登录 iCloud 并开启「iCloud 云盘」"
        }
        if dest.type == "quark" {
            if !quarkAppInstalled() {
                return "未检测到夸克客户端。安装后才能同步到云端；本地暂存目录可先创建，但不代表已上云"
            }
            if let root = backupRoot(for: dest) {
                return "本地暂存：\(root.path) · ClipVault 只写本机；需在夸克里把该目录加入「备份/同步」才会上云"
            }
            return "无法创建夸克暂存目录"
        }
        if dest.type == "folder", backupRoot(for: dest) == nil {
            return "路径无效或未配置"
        }
        return nil
    }

    /// Merge legacy single-root configs with default multi-dest list.
    static func normalizeDestinations(_ list: [BackupDestinationConfig]?) -> [BackupDestinationConfig] {
        var dests = list ?? []
        if dests.isEmpty {
            dests = BackupDestinationConfig.defaultList
        }
        // Ensure known defaults exist (upgrade path)
        if !dests.contains(where: { $0.id == "icloud" }) {
            dests.insert(.icloudDefault, at: 0)
        }
        if !dests.contains(where: { $0.id == "gdrive" }) {
            dests.append(.gdriveDefault)
        }
        if !dests.contains(where: { $0.id == "quark" }) {
            dests.append(.quarkDefault)
        }
        return dests
    }
}
