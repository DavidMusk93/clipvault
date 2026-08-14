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


/// Auto-discovered Quark client state (no File Provider mount).
struct QuarkDiscoveryReport: Codable, Equatable {
    var appInstalled: Bool
    var appPath: String?
    var accountConfigFound: Bool
    /// Named backup switches from Quark account.json (desktop/documents/downloads/…).
    var categoryBackupEnabled: [String: Bool]
    var anyCategoryBackupEnabled: Bool
    var menuAutoBackupEnable: Bool?
    var stagingPath: String?
    var stagingHasArtifact: Bool
    var cloudListedClipVaultBackups: Bool
    var summary: String
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


    /// Resolve backup root for a destination config.
    static func backupRoot(for dest: BackupDestinationConfig) -> URL? {
        switch dest.type {
        case "icloud":
            return cloudDocsURL()?.appendingPathComponent("ClipFlow/backup", isDirectory: true)
        case "gdrive":
            // Brand folder ClipVault. Prefer `cvbak` (fresh) because legacy
            // `ClipVault/backup` can wedge Google Drive File Provider (EDEADLK on every write).
            // Still accept existing backup / Keepsake paths if cvbak is not yet created
            // *and* the old tree is writable — resolver always returns cvbak first so new
            // writes land on a clean path; readers that only look at `backup/` keep legacy.
            guard let my = googleDriveMyDriveURL() else { return nil }
            let fresh = my.appendingPathComponent("ClipVault/cvbak", isDirectory: true)
            return fresh
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
    /// Quark: require app; staging path alone is not cloud readiness.
    static func isDestinationReady(_ dest: BackupDestinationConfig) -> Bool {
        guard backupRoot(for: dest) != nil else { return false }
        switch dest.type {
        case "quark":
            return quarkAppInstalled()
        default:
            return true
        }
    }

    // MARK: - Quark auto-discovery

    private static var quarkAppCandidates: [String] {
        [
            "/Applications/Quark.app",
            "/Applications/夸克网盘.app",
            "/Applications/夸克.app",
        ]
    }

    /// True if Quark Desktop (or legacy installer) appears installed.
    static func quarkAppInstalled() -> Bool {
        quarkAppPath() != nil
    }

    static func quarkAppPath() -> String? {
        quarkAppCandidates.first { fm.fileExists(atPath: $0) }
    }

    /// Prefer configured path, else well-known Quark staging / sync folders.
    /// Quark Desktop does not expose a File Provider mount like Google Drive;
    /// it can **backup a local folder**. We write to a dedicated staging root that
    /// the user adds once under 夸克 → 备份 / 上传位置 — path is **auto**, not manual.
    static func quarkStagingURL(configuredPath: String? = nil) -> URL? {
        if let p = configuredPath?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url.standardizedFileURL
        }
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
                let nested = c.appendingPathComponent("ClipVault/backup", isDirectory: true)
                try? fm.createDirectory(at: nested, withIntermediateDirectories: true)
                return nested.standardizedFileURL
            }
        }
        // Default staging — always auto-created; no user path hunting.
        let staging = home
            .appendingPathComponent("ClipVault-Backups/Quark/backup", isDirectory: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging.standardizedFileURL
    }

    /// Parse Quark client configs so UI does not ask users to "find" paths.
    static func discoverQuark() -> QuarkDiscoveryReport {
        let appPath = quarkAppPath()
        let appInstalled = appPath != nil
        let home = fm.homeDirectoryForCurrentUser
        let accountURL = home.appendingPathComponent("Library/Application Support/Quark/account.json")
        let prefURL = home.appendingPathComponent("Library/Application Support/Quark/preference.json")
        var categories: [String: Bool] = [:]
        var accountFound = false
        if let data = try? Data(contentsOf: accountURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            accountFound = true
            // account.json is { "<uid>": { desktopBackup: {enable:bool}, ... } }
            for (_, val) in root {
                guard let user = val as? [String: Any] else { continue }
                for key in ["desktopBackup", "documentsBackup", "downloadsBackup", "officeBackup", "qqBackup", "weixinBackup"] {
                    if let box = user[key] as? [String: Any], let en = box["enable"] as? Bool {
                        categories[key] = en
                    }
                }
                // specify custom folders if present
                if let specify = user["specify"] as? [String: Any] {
                    if let folders = specify["folders"] as? [[String: Any]] {
                        categories["specifyCustomFolders"] = !folders.isEmpty
                    } else if let paths = specify["paths"] as? [String] {
                        categories["specifyCustomFolders"] = !paths.isEmpty
                    } else if specify["setting"] != nil {
                        // setting exists but categories may still be off
                        categories["specifySettingPresent"] = true
                    }
                }
            }
        }
        var menuAuto: Bool? = nil
        if let data = try? Data(contentsOf: prefURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let global = root["global:setting"] as? [String: Any],
           let menu = global["menuSwitch"] as? [String: Any],
           let ab = menu["autoBackupEnable"] as? Bool {
            menuAuto = ab
        }
        let staging = quarkStagingURL(configuredPath: nil)
        var hasArtifact = false
        if let s = staging {
            let legacy = s.appendingPathComponent("latest/clipflow.db")
            if fm.fileExists(atPath: legacy.path) {
                hasArtifact = true
            } else if let hosts = try? fm.contentsOfDirectory(at: s.appendingPathComponent("hosts", isDirectory: true), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                hasArtifact = hosts.contains {
                    fm.fileExists(atPath: $0.appendingPathComponent("latest/clipflow.db").path)
                }
            }
        }
        // Best-effort: IndexedDB cloud listing mentions ClipVault-Backups (user uploaded/synced name).
        var cloudListed = false
        let idb = home.appendingPathComponent(
            "Library/Application Support/Quark/Default/IndexedDB/uccd_cloud.quark_0.indexeddb.leveldb"
        )
        if let files = try? fm.contentsOfDirectory(at: idb, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "log" || f.pathExtension == "ldb" {
                if let data = try? Data(contentsOf: f), data.count < 8_000_000 {
                    if data.range(of: Data("ClipVault-Backups".utf8)) != nil {
                        cloudListed = true
                        break
                    }
                }
            }
        }
        let anyCat = categories.contains { $0.key.hasSuffix("Backup") && $0.value == true }
        var parts: [String] = []
        if appInstalled { parts.append("已安装客户端") } else { parts.append("未安装客户端") }
        if accountFound {
            let on = categories.filter { $0.key.hasSuffix("Backup") && $0.value }.map(\.key)
            if on.isEmpty {
                parts.append("电脑备份分类均未开启（桌面/文档/下载…）")
            } else {
                parts.append("已开启: " + on.joined(separator: ", "))
            }
        }
        if hasArtifact { parts.append("本机暂存已有 ClipVault 制品") }
        if cloudListed { parts.append("夸克云端目录列表出现 ClipVault-Backups") }
        if let staging {
            parts.append("暂存: \(staging.path)")
        }
        return QuarkDiscoveryReport(
            appInstalled: appInstalled,
            appPath: appPath,
            accountConfigFound: accountFound,
            categoryBackupEnabled: categories,
            anyCategoryBackupEnabled: anyCat,
            menuAutoBackupEnable: menuAuto,
            stagingPath: staging?.path,
            stagingHasArtifact: hasArtifact,
            cloudListedClipVaultBackups: cloudListed,
            summary: parts.joined(separator: " · ")
        )
    }

    static func availabilityHint(for dest: BackupDestinationConfig) -> String? {
        if dest.type == "gdrive", googleDriveMyDriveURL() == nil {
            return "请安装并登录 Google Drive for Desktop，登录后出现 CloudStorage/GoogleDrive-* 即可"
        }
        if dest.type == "icloud", cloudDocsURL() == nil {
            return "请登录 iCloud 并开启「iCloud 云盘」"
        }
        if dest.type == "quark" {
            let d = discoverQuark()
            if !d.appInstalled {
                return "未检测到夸克客户端。安装后 ClipVault 会自动写入暂存目录（无需手填路径）"
            }
            // Honest model: ClipVault only writes local staging. Quark client must upload.
            var lines: [String] = []
            lines.append("ClipVault→本机暂存（无夸克 File Provider，无法整包校验云端）")
            if let p = d.stagingPath {
                lines.append("路径: \(p)")
            }
            if d.stagingHasArtifact {
                lines.append("本机制品已就位")
            }
            if d.cloudListedClipVaultBackups {
                lines.append("夸克云端列表可见 ClipVault-Backups（不等于 blobs 全量校验）")
            } else {
                lines.append("尚未在夸克云端列表看到 ClipVault-Backups")
            }
            if d.accountConfigFound && !d.anyCategoryBackupEnabled {
                lines.append("夸克「电脑备份」分类均为关：请在夸克将 ClipVault-Backups 加入备份/上传，或手动上传该文件夹")
            }
            return lines.joined(separator: " · ")
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
