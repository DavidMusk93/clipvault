import Foundation

#if INKSTONE
import InkstoneFFI
#endif

/// Shadow copy of the note set in the inkstone engine.
///
/// The authoritative path stays ClipVault's own storage: this mirrors every
/// saved note into an inkstone vault so the engine can be exercised on real
/// data (search, warmth, backup) before it becomes the writer. It is:
///
/// * **opt-in** — `CLIPVAULT_INKSTONE_SHADOW=1`, otherwise every call is a no-op;
/// * **off the request path** — work happens on its own serial queue, and a
///   failure is logged once, never surfaced to the editor;
/// * **projection-only** — it writes the markdown ClipVault already stores, so a
///   shadow vault can be thrown away and rebuilt at any time.
final class InkstoneShadow {
    static let shared = InkstoneShadow()

    /// Vault file, or nil when the shadow is disabled.
    let path: String?

    private let queue = DispatchQueue(label: "clipvault.inkstone.shadow", qos: .utility)
    private var vault: AnyObject?
    private var openFailed = false
    private var lastError: String?
    private var errorCount = 0

    private init() {
        let env = ProcessInfo.processInfo.environment
        guard env["CLIPVAULT_INKSTONE_SHADOW"] == "1" else {
            path = nil
            return
        }
        let home = env["CLIPVAULT_HOME"]
            ?? (NSHomeDirectory() + "/Library/Application Support/Keepsake")
        path = env["CLIPVAULT_INKSTONE_PATH"] ?? (home + "/inkstone.db")
    }

    var enabled: Bool { path != nil }

    /// Mirror one note. `markdown` is ClipVault's stored body, `updatedAt` its
    /// timestamp.
    func mirror(id: String, markdown: String, updatedAt: Date) {
        #if INKSTONE
        guard enabled, let path else { return }
        let ms = Int64(updatedAt.timeIntervalSince1970 * 1000)
        queue.async { [weak self] in
            guard let self, let vault = self.openVault(path) else { return }
            do {
                if let existing = try vault.load(id: id) {
                    try existing.setMarkdown(markdown: markdown)
                    _ = try vault.saveAndIndex(note: existing)
                } else {
                    _ = try vault.importMarkdown(
                        markdown: markdown,
                        id: id,
                        createdAt: ms,
                        updatedAt: ms
                    )
                }
            } catch {
                self.record(error)
            }
        }
        #else
        _ = (id, markdown, updatedAt)
        #endif
    }

    /// Drop a note from the shadow copy.
    func forget(id: String) {
        #if INKSTONE
        guard enabled, let path else { return }
        queue.async { [weak self] in
            guard let self, let vault = self.openVault(path) else { return }
            _ = try? vault.delete(id: id)
        }
        #else
        _ = id
        #endif
    }

    /// Notes whose body contains `query`, straight from the engine's index.
    func probe(query: String, limit: UInt32 = 10) -> [[String: Any]]? {
        #if INKSTONE
        guard enabled, let path else { return nil }
        var out: [[String: Any]] = []
        queue.sync {
            guard let vault = openVault(path) else { return }
            guard let hits = try? vault.search(query: query, limit: limit) else { return }
            out = hits.map { ["id": $0.noteId, "title": $0.title, "snippet": $0.snippet] }
        }
        return out
        #else
        _ = (query, limit)
        return nil
        #endif
    }

    func stats() -> [String: Any]? {
        #if INKSTONE
        guard enabled, let path else { return nil }
        var out: [String: Any]?
        queue.sync {
            guard let vault = openVault(path) else { return }
            guard let json = try? vault.statsJson() else { return }
            var payload = (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
                as? [String: Any] ?? [:]
            payload["path"] = path
            payload["lastError"] = lastError
            payload["errorCount"] = errorCount
            out = payload
        }
        return out
        #else
        return nil
        #endif
    }

    #if INKSTONE
    private func openVault(_ path: String) -> VaultHandle? {
        if let vault = self.vault as? VaultHandle { return vault }
        if openFailed { return nil }
        do {
            let handle = try VaultHandle.open(path: path)
            self.vault = handle
            return handle
        } catch {
            openFailed = true
            fputs("[inkstone-shadow] open failed (\(path)): \(error)\n", stderr)
            return nil
        }
    }

    private func record(_ error: Error) {
        errorCount += 1
        if lastError == nil {
            lastError = String(describing: error)
            fputs("[inkstone-shadow] mirror failed: \(error)\n", stderr)
        }
    }
    #endif
}
