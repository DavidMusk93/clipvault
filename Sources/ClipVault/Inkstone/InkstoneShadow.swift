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

    /// `CLIPVAULT_INKSTONE_PRIMARY=1` moves the note write path into the engine:
    /// a note is written to the vault **first**, and only then projected into
    /// ClipVault's own tables. Off means the old path stays authoritative.
    let isPrimary: Bool

    private let queue = DispatchQueue(label: "clipvault.inkstone.shadow", qos: .utility)
    private var vault: AnyObject?
    private var openFailed = false
    private var lastError: String?
    private var errorCount = 0
    private var syncSessions: [String: AnyObject] = [:]

    private init() {
        let env = ProcessInfo.processInfo.environment
        isPrimary = env["CLIPVAULT_INKSTONE_PRIMARY"] == "1"
        guard isPrimary || env["CLIPVAULT_INKSTONE_SHADOW"] == "1" else {
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

    /// Engine-first write. Returns false when the engine refused, and the caller
    /// must then fail the save instead of letting the projection drift.
    func writePrimary(id: String, markdown: String, updatedAt: Date) -> Bool {
        #if INKSTONE
        guard isPrimary, let path, let vault = openVault(path) else { return false }
        let ms = Int64(updatedAt.timeIntervalSince1970 * 1000)
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
            return true
        } catch {
            record(error)
            return false
        }
        #else
        _ = (id, markdown, updatedAt)
        return false
        #endif
    }

    /// The engine's markdown for a note (audit / repair).
    func engineMarkdown(id: String) -> String? {
        #if INKSTONE
        guard let path, let vault = openVault(path) else { return nil }
        guard let note = try? vault.load(id: id) else { return nil }
        return note.markdown()
        #else
        _ = id
        return nil
        #endif
    }

    /// Writing sessions the engine recorded — the warmth reading once the engine
    /// owns the write path.
    func editSessions(id: String) -> Int? {
        #if INKSTONE
        guard let path, let vault = openVault(path) else { return nil }
        guard let activity = try? vault.activity(id: id) else { return nil }
        return Int(activity.sessions) + (activity.inProgress ? 1 : 0)
        #else
        _ = id
        return nil
        #endif
    }

    /// Consistent copy of the vault, for the snapshot taken before a flip.
    func backup(to path: String) -> UInt64? {
        #if INKSTONE
        guard let vaultPath = self.path, let vault = openVault(vaultPath) else { return nil }
        return try? vault.backupTo(path: path)
        #else
        _ = path
        return nil
        #endif
    }

    /// First message of a note sync ("here is what this vault has").
    func syncHello(note: String) -> Data? {
        #if INKSTONE
        guard enabled, let session = self.session(note) else { return nil }
        return try? session.hello()
        #else
        _ = note
        return nil
        #endif
    }

    /// Feed one opaque peer message; returns the messages to hand back.
    func syncReceive(note: String, message: Data) -> [Data]? {
        #if INKSTONE
        guard enabled, let session = self.session(note) else { return nil }
        return try? session.receive(message: message)
        #else
        _ = (note, message)
        return nil
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
    /// Sessions live per note; a transport may open, use and drop one per request.
    private func session(_ note: String) -> SyncHandle? {
        if let existing = syncSessions[note] as? SyncHandle { return existing }
        guard let path, let vault = openVault(path) else { return nil }
        guard let handle = try? vault.syncHandle(note: note) else { return nil }
        syncSessions[note] = handle as AnyObject
        return handle
    }

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
