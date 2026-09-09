import Darwin
import Dispatch
import Foundation

/// POSIX byte sink used by the UDS origin. The browser never sees this socket.
final class HTTPByteSink {
    let fd: Int32
    private let lock = NSLock()
    private var closed = false
    private var closeHandlers: [() -> Void] = []
    private var readSource: DispatchSourceRead?

    init(fd: Int32) {
        self.fd = fd
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func send(content: Data, completion: @escaping (Error?) -> Void) {
        if content.isEmpty {
            completion(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [fd] in
            var offset = 0
            var sendErr: Error?
            content.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                while offset < content.count {
                    let n = Darwin.send(fd, base + offset, content.count - offset, 0)
                    if n <= 0 {
                        sendErr = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        break
                    }
                    offset += Int(n)
                }
            }
            completion(sendErr)
        }
    }

    func receive(
        minimumIncompleteLength: Int,
        maximumLength: Int,
        completion: @escaping (Data?, Bool, Error?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [fd] in
            var buf = [UInt8](repeating: 0, count: max(1, maximumLength))
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            if n == 0 {
                completion(nil, true, nil)
                return
            }
            if n < 0 {
                completion(nil, true, POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                return
            }
            _ = minimumIncompleteLength
            completion(Data(buf.prefix(Int(n))), false, nil)
        }
    }

    func watchPeerClose(_ handler: @escaping () -> Void) {
        lock.lock()
        if closed {
            lock.unlock()
            handler()
            return
        }
        closeHandlers.append(handler)
        if readSource == nil {
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .utility))
            src.setEventHandler { [weak self] in
                guard let self else { return }
                var b: UInt8 = 0
                let n = Darwin.recv(self.fd, &b, 1, Int32(MSG_PEEK))
                if n <= 0 { self.cancel() }
            }
            src.resume()
            readSource = src
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        readSource?.cancel()
        readSource = nil
        let handlers = closeHandlers
        closeHandlers.removeAll()
        lock.unlock()
        Darwin.close(fd)
        for h in handlers { h() }
    }
}

final class OriginUnixServer {
    static let shared = OriginUnixServer()
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private(set) var path: String = ""

    func start(path: String, onAccept: @escaping (HTTPByteSink) -> Void) {
        self.path = path
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("[Origin] socket failed errno=\(errno)")
            return
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { cstr in
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                let n = min(dest.count - 1, strlen(cstr))
                if let base = dest.baseAddress {
                    memcpy(base, cstr, n)
                }
            }
        }
        let socklen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen)
            }
        }
        guard bindRc == 0 else {
            print("[Origin] bind \(path) failed errno=\(errno)")
            Darwin.close(fd)
            return
        }
        chmod(path, 0o600)
        guard listen(fd, 256) == 0 else {
            print("[Origin] listen failed errno=\(errno)")
            Darwin.close(fd)
            return
        }
        listenFd = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .userInitiated))
        src.setEventHandler {
            let cfd = accept(fd, nil, nil)
            if cfd >= 0 {
                onAccept(HTTPByteSink(fd: cfd))
            }
        }
        src.resume()
        acceptSource = src
        print("[Origin] unix \(path)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFd >= 0 {
            Darwin.close(listenFd)
            listenFd = -1
        }
        if !path.isEmpty { unlink(path) }
    }
}
