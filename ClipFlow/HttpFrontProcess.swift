import Foundation

/// Supervises the Rust HTTPS/2 edge. Browser talks to one TCP port; this process
/// is the only public listener.
final class HttpFrontProcess {
    static let shared = HttpFrontProcess()
    private var proc: Process?
    private var restarting = false

    func start(originSock: String, listen: String = "127.0.0.1:8080,[::1]:8080") {
        stop()
        guard let bin = Self.binaryURL() else {
            print("[HTTP2] clipvault-http binary missing next to ClipFlowServer")
            return
        }
        let p = Process()
        p.executableURL = bin
        var env = ProcessInfo.processInfo.environment
        env["CLIPVAULT_ORIGIN"] = originSock
        env["CLIPVAULT_LISTEN"] = listen
        env["CLIPVAULT_TLS_DIR"] = DatabaseManager.resolveDataRoot()
            .appendingPathComponent("tls", isDirectory: true).path
        if env["KEEPSAKE_HOME"] == nil {
            env["KEEPSAKE_HOME"] = DatabaseManager.resolveDataRoot().path
        }
        env["CLIPVAULT_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        p.environment = env
        p.standardOutput = FileHandle.standardOutput
        p.standardError = FileHandle.standardError
        p.terminationHandler = { [weak self] proc in
            print("[HTTP2] clipvault-http exit status=\(proc.terminationStatus)")
            self?.scheduleRestart(originSock: originSock, listen: listen)
        }
        do {
            try p.run()
            self.proc = p
            print("[HTTP2] clipvault-http pid=\(p.processIdentifier) listen=\(listen)")
        } catch {
            print("[HTTP2] spawn failed: \(error)")
        }
    }

    func stop() {
        proc?.terminationHandler = nil
        proc?.terminate()
        proc = nil
    }

    private func scheduleRestart(originSock: String, listen: String) {
        guard !restarting else { return }
        restarting = true
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.restarting = false
            self?.start(originSock: originSock, listen: listen)
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
