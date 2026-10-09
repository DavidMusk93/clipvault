import Darwin
import Foundation

/// Exactly one `ClipVaultServer` owns a data home.
///
/// Two servers on the same `$CLIPVAULT_HOME` each open the SQLite writer, run
/// their own sync + backup loops, and `OriginUnixServer.start()` unlinks and
/// rebinds `run/http.sock` — so the second silently steals the origin socket
/// from the first while its `clipvault-http` fights for :80/:443 (the
/// 2026-10-09 `Address already in use` + `exit status=2` loop).
///
/// `flock` is released by the kernel when the owner dies, so a crash never
/// wedges startup; a stale lock file with no live holder is re-acquired.
final class SingleInstanceLock {
    let path: String
    private let fd: Int32

    private init(path: String, fd: Int32) {
        self.path = path
        self.fd = fd
    }

    /// Non-blocking exclusive acquire. `nil` means another live process holds it.
    static func acquire(path: String) -> SingleInstanceLock? {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // O_CLOEXEC: the spawned clipvault-http child must not inherit the lock.
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        // Diagnostics only — the flock, not this text, is the authority.
        let stamp = "pid=\(getpid()) started=\(ISO8601DateFormatter().string(from: Date()))\n"
        if ftruncate(fd, 0) == 0, let data = stamp.data(using: .utf8) {
            _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        }
        return SingleInstanceLock(path: path, fd: fd)
    }

    /// Pid recorded in the lock file (diagnostics; may be a dead holder).
    static func ownerPid(path: String) -> Int32? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let range = text.range(of: "pid=") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return Int32(digits)
    }

    func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }

    deinit { release() }
}
