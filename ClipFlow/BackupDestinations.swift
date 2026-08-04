import Foundation

/// Pluggable backup destination (folder-backed: iCloud Drive, Google Drive, custom path).
/// Artifact is produced once (sqlite3_backup + CAS blobs), then fan-out to each enabled root.
struct BackupDestinationConfig: Codable, Equatable, Identifiable {
    var id: String
    /// `icloud` | `gdrive` | `folder`
    var type: String
    var enabled: Bool
    var label: String?
    /// Absolute path when type == folder
    var path: String?

    static let icloudDefault = BackupDestinationConfig(
        id: "icloud", type: "icloud", enabled: true, label: "iCloud Drive", path: nil
    )
    static let gdriveDefault = BackupDestinationConfig(
        id: "gdrive", type: "gdrive", enabled: true, label: "Google Drive", path: nil
    )

    static var defaultList: [BackupDestinationConfig] {
        [.icloudDefault, .gdriveDefault]
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

    /// Resolve backup root for a destination config.
    static func backupRoot(for dest: BackupDestinationConfig) -> URL? {
        switch dest.type {
        case "icloud":
            return cloudDocsURL()?.appendingPathComponent("ClipFlow/backup", isDirectory: true)
        case "gdrive":
            return googleDriveMyDriveURL()?.appendingPathComponent("Keepsake/backup", isDirectory: true)
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
        case "folder": return dest.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Folder"
        default: return dest.id
        }
    }

    static func availabilityHint(for dest: BackupDestinationConfig) -> String? {
        if dest.type == "gdrive", googleDriveMyDriveURL() == nil {
            return "请安装并登录 Google Drive for Desktop，登录后出现 CloudStorage/GoogleDrive-* 即可"
        }
        if dest.type == "icloud", cloudDocsURL() == nil {
            return "请登录 iCloud 并开启「iCloud 云盘」"
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
        return dests
    }
}
