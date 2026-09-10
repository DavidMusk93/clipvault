import Foundation

/// An offline archive is a **root document** plus every CAS object it names.
///
/// Sync does not treat CAS as a protocol. The transaction lists the closure in
/// `web_archive.blob_keys`; the cloud only transports those files (`live/attach`).
/// Backup host slices are replicas for hydrate/repair, never the sync bus.
///
/// New View asset kinds (srcset, fonts, object) add a regex here — no new trx kind.
enum ArchiveBlobClosure {
    /// Recognized pointers inside archive HTML. Case-insensitive; capture group 1 = sha256 hex.
    private static let patterns: [NSRegularExpression] = {
        let raw = [
            #"\/api\/archive\/asset\?sha=([0-9a-f]{64})"#,
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    /// Dependent CAS hashes named by the document (not including the HTML root).
    static func refs(inHTML html: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        for re in patterns {
            re.enumerateMatches(in: html, options: [], range: full) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let sha = ns.substring(with: match.range(at: 1)).lowercased()
                guard ArchiveImageInliner.isAssetSHA(sha), !seen.contains(sha) else { return }
                seen.insert(sha)
                out.append(sha)
            }
        }
        return out
    }

    /// Wire list: root first, then unique dependents. This **is** `blob_keys`.
    static func keys(root: String, html: String) -> [String] {
        let root = root.lowercased()
        var keys: [String] = []
        var seen = Set<String>()
        if ArchiveImageInliner.isAssetSHA(root) {
            keys.append(root)
            seen.insert(root)
        }
        for sha in refs(inHTML: html) where !seen.contains(sha) {
            seen.insert(sha)
            keys.append(sha)
        }
        return keys
    }

    static func parseMeta(_ raw: String?) -> [String: Any] {
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    static func encodeMeta(_ obj: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Record the closure on archive meta so repair can diff without a new trx kind.
    @discardableResult
    static func stamp(_ meta: inout [String: Any], root: String, html: String) -> [String] {
        let keys = keys(root: root, html: html)
        meta["closure"] = [
            "v": 1,
            "root": root.lowercased(),
            "blobs": keys,
        ] as [String: Any]
        meta["imagesOffline"] = !ArchiveImageInliner.containsRemoteImages(html)
        return keys
    }

    static func blobs(fromMeta raw: String?) -> [String]? {
        let meta = parseMeta(raw)
        guard let closure = meta["closure"] as? [String: Any],
              let blobs = closure["blobs"] as? [String] else { return nil }
        return blobs.map { $0.lowercased() }
    }
}
