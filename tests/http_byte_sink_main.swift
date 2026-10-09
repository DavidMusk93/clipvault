import Darwin
import Dispatch
import Foundation

/// Compile: swiftc -parse-as-library -O tests/http_byte_sink_main.swift Sources/ClipVault/HTTP/HTTPByteSink.swift
///
/// Regression gate for the 2026-10-09 crash: `HTTPByteSink.cancel()` called `Darwin.close(fd)`
/// immediately after `readSource.cancel()` (async). A live `DispatchSourceRead` registration was
/// left behind on a closed — then recycled — fd number, so libdispatch's event loop hit
/// `_dispatch_bug_kevent_vanished` -> `_dispatch_source_merge_evt` -> EXC_BAD_ACCESS at 0x10 and
/// killed ClipVaultServer three times during a 4271-op pull replay (12:06:51 / 12:08:52 / 12:13:30).
///
/// Primary assertion is deterministic and does not need a crash: with a live read source,
/// `cancel()` must hand the fd to the source's cancel handler instead of closing it inline.
/// The stress loops stay as a crash canary — a SIGSEGV shows up as a non-zero exit status.
@main
enum HTTPByteSinkTests {
    static func main() {
        var failures = 0
        func ok(_ name: String, _ cond: Bool, _ detail: String = "") {
            if cond {
                print("OK \(name)")
            } else {
                FileHandle.standardError.write(Data("FAIL \(name) \(detail)\n".utf8))
                failures += 1
            }
        }

        // A. fd ownership: not closed while the read source is still live; closed once it is gone.
        if let (a, b) = socketPair() {
            let sink = HTTPByteSink(fd: a)
            sink.watchPeerClose {}          // installs the DispatchSourceRead on fd `a`
            sink.cancel()
            let openAfterCancel = fcntl(a, F_GETFD) >= 0
            ok(
                "fd-kept-open-until-source-cancels",
                openAfterCancel,
                "fd \(a) was closed while its read source was still registered"
            )
            var closedLater = false
            for _ in 0..<500 where !closedLater {
                if fcntl(a, F_GETFD) < 0 { closedLater = true; break }
                usleep(1000)
            }
            ok("fd-closed-after-source-cancel", closedLater, "fd \(a) never closed")
            sink.cancel()
            ok("cancel-idempotent", fcntl(a, F_GETFD) < 0)
            _ = Darwin.close(b)
        }

        // B. Canary: peer closes, concurrent cancels, immediate fd-number reuse + event pressure.
        var handlerFired = 0
        for _ in 0..<600 {
            guard let (a, b) = socketPair() else { break }
            let sink = HTTPByteSink(fd: a)
            let done = DispatchSemaphore(value: 0)
            sink.watchPeerClose {
                handlerFired += 1
                done.signal()
            }
            Thread.detachNewThread { _ = Darwin.close(b) }
            Thread.detachNewThread { sink.cancel() }
            _ = done.wait(timeout: .now() + 1)
            sink.cancel()
            // Recycle the fd number straight away and make the event loop fire on it.
            if let (c, d) = socketPair() {
                let sink2 = HTTPByteSink(fd: c)
                sink2.watchPeerClose {}
                _ = Darwin.write(d, "x", 1)
                usleep(200)
                sink2.cancel()
                _ = Darwin.close(d)
            }
        }
        ok("stress-peer-close-and-fd-reuse", handlerFired > 0, "handlers=\(handlerFired)")

        // C. OriginUnixServer start/stop (listen-fd path) with a client connecting in between.
        var accepted = 0
        let sockPath = "/tmp/cv-http-byte-sink-\(getpid()).sock"
        for i in 0..<150 {
            OriginUnixServer.shared.start(path: sockPath) { sink in
                accepted += 1
                sink.cancel()
            }
            if let cfd = connectUnix(sockPath) {
                _ = Darwin.write(cfd, "x", 1)
                usleep(200)
                _ = Darwin.close(cfd)
            }
            OriginUnixServer.shared.stop()
            if i % 50 == 0 { usleep(1000) }
        }
        ok("origin-server-start-stop", accepted > 0, "accepted=\(accepted)")

        // D. send() in flight while the peer disappears and the sink is cancelled.
        var completions = 0
        for _ in 0..<100 {
            guard let (a, b) = socketPair() else { break }
            let sink = HTTPByteSink(fd: a)
            sink.watchPeerClose {}
            let flushed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                sink.send(content: Data(repeating: 0x41, count: 4096)) { _ in
                    completions += 1
                    flushed.signal()
                }
            }
            Thread.detachNewThread { _ = Darwin.close(b) }
            sink.cancel()
            if flushed.wait(timeout: .now() + 2) == .success { completions += 0 }
        }
        ok("send-completes-during-cancel", completions > 0, "completions=\(completions)")

        // E. Close callbacks: fire once per registration, also when the sink is already closed.
        var callbacks = 0
        if let (a, b) = socketPair() {
            let sink = HTTPByteSink(fd: a)
            sink.watchPeerClose { callbacks += 1 }
            sink.cancel()
            sink.cancel()
            sink.watchPeerClose { callbacks += 1 }
            _ = Darwin.close(b)
            ok("close-handlers-once", callbacks == 2, "callbacks=\(callbacks)")
        }

        if failures > 0 {
            FileHandle.standardError.write(Data("FAILURES \(failures)\n".utf8))
            exit(1)
        }
        print("http_byte_sink: OK")
    }

    static func socketPair() -> (Int32, Int32)? {
        var fds: [Int32] = [0, 0]
        let rc = fds.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return socketpair(AF_UNIX, SOCK_STREAM, 0, base)
        }
        guard rc == 0 else { return nil }
        return (fds[0], fds[1])
    }

    static func connectUnix(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { cstr in
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                let n = min(dest.count - 1, strlen(cstr))
                if let base = dest.baseAddress { memcpy(base, cstr, n) }
            }
        }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            _ = Darwin.close(fd)
            return nil
        }
        return fd
    }
}
