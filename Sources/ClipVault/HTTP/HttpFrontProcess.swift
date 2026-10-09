import Foundation

/// Supervises the Rust HTTP/2 process. Browser talks to one TCP port; this
/// process is the only HTTP listener. Origin on the unix socket is CV01, not HTTP.
final class HttpFrontProcess {
    static let shared = HttpFrontProcess()
    private var proc: Process?
    private var restarting = false
    private var restartAttempt = 0

    func start(originSock: String, listen: String = "127.0.0.1:80,[::1]:80", tls: Bool = false) {
        stop()
        guard let bin = Self.binaryURL() else {
            print("[HTTP] clipvault-http binary missing next to ClipVaultServer")
            return
        }
        let p = Process()
        p.executableURL = bin
        var env = ProcessInfo.processInfo.environment
        env["CLIPVAULT_ORIGIN"] = originSock
        env["CLIPVAULT_LISTEN"] = listen
        env["CLIPVAULT_TLS"] = tls ? "1" : "0"
        if tls {
            env["CLIPVAULT_TLS_DIR"] = DatabaseManager.resolveDataRoot()
                .appendingPathComponent("tls", isDirectory: true).path
        }
        if env["KEEPSAKE_HOME"] == nil {
            env["KEEPSAKE_HOME"] = DatabaseManager.resolveDataRoot().path
        }
        env["CLIPVAULT_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        p.environment = env
        p.standardOutput = FileHandle.standardOutput
        p.standardError = FileHandle.standardError
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            print("[HTTP] clipvault-http exit status=\(status)")
            self?.scheduleRestart(originSock: originSock, listen: listen, tls: tls, status: status)
        }
        do {
            try p.run()
            self.proc = p
            print("[HTTP] clipvault-http pid=\(p.processIdentifier) listen=\(listen) tls=\(tls)")
        } catch {
            print("[HTTP] spawn failed: \(error)")
        }
    }

    /// SIGTERM, then block until the child is reaped. :80/:443 is only free once
    /// the old listener is gone; spawning the next front while it still holds the
    /// socket is the 2026-10-09 `Address already in use` race.
    func stop() {
        guard let p = proc else { return }
        p.terminationHandler = nil
        proc = nil
        p.terminate()
        let deadline = Date().addingTimeInterval(3.0)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning {
            print("[HTTP] clipvault-http pid=\(p.processIdentifier) ignored SIGTERM; SIGKILL")
            kill(p.processIdentifier, SIGKILL)
            p.waitUntilExit()
        }
    }

    private func scheduleRestart(originSock: String, listen: String, tls: Bool, status: Int32) {
        guard !restarting else { return }
        restarting = true
        // Clean exit = orderly shutdown. A failed bind (2) means someone still
        // owns the port: back off instead of spinning a bind-fail loop.
        if status == 0 {
            restartAttempt = 0
        } else {
            restartAttempt = min(restartAttempt + 1, 5)
        }
        let delay = status == 0 ? 1.2 : min(1.2 * pow(2, Double(max(0, restartAttempt - 1))), 30)
        if status != 0 {
            print("[HTTP] clipvault-http failed status=\(status); retry #\(restartAttempt) in \(String(format: "%.1f", delay))s")
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.restarting = false
            self?.start(originSock: originSock, listen: listen, tls: tls)
        }
    }

    static func binaryURL() -> URL? {
        let fm = FileManager.default
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let next = exe.deletingLastPathComponent().appendingPathComponent("clipvault-http")
        if fm.isExecutableFile(atPath: next.path) { return next }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("http-front/target/release/clipvault-http")
        if fm.isExecutableFile(atPath: cwd.path) { return cwd }
        return nil
    }
}
