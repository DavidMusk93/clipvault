import Foundation

/// Stable per-install host id. Shared by live sync and per-machine backup.
/// File: `KEEPSAKE_HOME/config/host.json`.
enum ClipHostIdentity {
    struct Record: Codable {
        var hostId: String
        var label: String?
    }

    static var id: String { loadOrCreate().hostId }

    static var label: String { loadOrCreate().label ?? ProcessInfo.processInfo.hostName }

    static func loadOrCreate() -> Record {
        let root = DatabaseManager.resolveDataRoot()
        let url = root.appendingPathComponent("config/host.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: url),
           let rec = try? JSONDecoder().decode(Record.self, from: data),
           !rec.hostId.isEmpty {
            return rec
        }
        let hostName = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
            .replacingOccurrences(of: " ", with: "-")
        let short = String(UUID().uuidString.prefix(8)).lowercased()
        let rec = Record(
            hostId: "\(hostName)-\(short)",
            label: ProcessInfo.processInfo.hostName
        )
        if let data = try? JSONEncoder().encode(rec) {
            try? data.write(to: url, options: .atomic)
        }
        return rec
    }
}
