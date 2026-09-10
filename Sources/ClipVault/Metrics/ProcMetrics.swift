import Darwin
import Foundation

/// Live process resource snapshot for ClipVaultServer. No note content.
enum ProcMetrics {
    struct Sample {
        var fds: Int
        var rlim: Int
        var rssMb: Int
        var sockets: Int
        var sse: Int

        func asDict() -> [String: Int] {
            [
                "fds": fds,
                "rss": rssMb,
                "unix": sockets,
                "sse": sse,
                "rlim": rlim,
            ]
        }

        func asJSON(ok: Bool) -> [String: Any] {
            [
                "ok": ok,
                "ts": Int(Date().timeIntervalSince1970 * 1000),
                "pid": Int(getpid()),
                "fds": fds,
                "rss": rssMb,
                "unix": sockets,
                "sse": sse,
                "rlim": rlim,
            ]
        }

        var strained: Bool {
            let cap = max(rlim, 1)
            return fds * 2 >= cap || sse >= 32 || sockets >= 128
        }
    }

    static func sample(sse: Int) -> Sample {
        var lim = rlimit()
        getrlimit(RLIMIT_NOFILE, &lim)
        var rlim = Int(lim.rlim_cur)
        if lim.rlim_cur == rlim_t.max || rlim <= 0 { rlim = 10240 }
        let counts = fdCounts()
        return Sample(
            fds: counts.fds,
            rlim: rlim,
            rssMb: rssMb(),
            sockets: counts.sockets,
            sse: sse
        )
    }

    private static func rssMb() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / (1024 * 1024))
    }

    private static let PROC_PIDLISTFDS: Int32 = 1
    private static let PROX_FDTYPE_SOCKET: UInt32 = 2

    private struct ProcFdInfo {
        var proc_fd: Int32
        var proc_fdtype: UInt32
    }

    private static func fdCounts() -> (fds: Int, sockets: Int) {
        let pid = getpid()
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return (fdsFromDevFd(), 0) }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(needed), alignment: 8)
        defer { buf.deallocate() }
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buf, needed)
        guard got > 0 else { return (fdsFromDevFd(), 0) }
        let n = Int(got) / MemoryLayout<ProcFdInfo>.size
        let list = buf.bindMemory(to: ProcFdInfo.self, capacity: n)
        var sockets = 0
        for i in 0..<n {
            if list[i].proc_fdtype == PROX_FDTYPE_SOCKET { sockets += 1 }
        }
        return (n, sockets)
    }

    private static func fdsFromDevFd() -> Int {
        guard let dir = opendir("/dev/fd") else { return 0 }
        defer { closedir(dir) }
        var n = 0
        while let ent = readdir(dir) {
            if ent.pointee.d_name.0 == 46 { continue } // '.'
            n += 1
        }
        return n
    }
}

@_silgen_name("proc_pidinfo")
private func proc_pidinfo(
    _ pid: Int32,
    _ flavor: Int32,
    _ arg: UInt64,
    _ buffer: UnsafeMutableRawPointer?,
    _ buffersize: Int32
) -> Int32
