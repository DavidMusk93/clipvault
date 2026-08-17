import Foundation
import CryptoKit

/// Compose layer helpers. Notes are `ClipboardType.note` rows; edits append `compose_ops`.
enum ComposeNotes {
    static let sourceApp = "ClipVault"
    static let refScheme = "clipvault"

    static func normalizedBody(title: String?, body: String) -> String {
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let b = body.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return b }
        if b.hasPrefix("# ") { return b }
        if b.isEmpty { return "# \(t)" }
        return "# \(t)\n\n\(b)"
    }

    static func contentHash(id: UUID, body: String) -> String {
        let seed = "compose\n\(id.uuidString.lowercased())\n\(body)"
        return SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func refURL(from raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let uuid = UUID(uuidString: raw) else { return nil }
        return URL(string: "\(refScheme)://item/\(uuid.uuidString)")
    }

    static func refId(from url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == refScheme else { return nil }
        let last = url.path.split(separator: "/").last.map(String.init) ?? url.host
        guard let last, UUID(uuidString: last) != nil else { return nil }
        return last
    }

    static func blobKeys(in markdown: String) -> [String] {
        let pattern = #"/api/(?:image|archive/asset)\?sha=([0-9a-f]{64})"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = markdown as NSString
        let range = NSRange(location: 0, length: ns.length)
        var seen = Set<String>()
        var out: [String] = []
        re.enumerateMatches(in: markdown, options: [], range: range) { m, _, _ in
            guard let m, m.numberOfRanges >= 2 else { return }
            let sha = ns.substring(with: m.range(at: 1)).lowercased()
            guard ArchiveImageInliner.isAssetSHA(sha), !seen.contains(sha) else { return }
            seen.insert(sha)
            out.append(sha)
        }
        return out
    }
}
