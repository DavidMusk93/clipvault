import Darwin
import Dispatch
import Foundation

/// Compile:
///   swiftc -parse-as-library -O tests/single_instance_main.swift \
///     Sources/ClipVault/App/SingleInstanceLock.swift -o /tmp/clipvault-single-instance-test
///
/// Regression gate for the 2026-10-09 "two ClipVaultServer" incident: nothing
/// stopped a second process from opening the same $CLIPVAULT_HOME, stealing
/// run/http.sock and fighting for :80/:443. `SingleInstanceLock` is the one
/// owner guard. These tests are aggressive on purpose: in-process contention,
/// a real child process, and a 64-way race must all yield exactly one owner.
@main
enum SingleInstanceLockTests {
    static func main() {
        // Child mode: try to acquire a lock the parent already holds.
        // exit 0 = correctly refused, 1 = wrongly acquired.
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--child" {
            let lock = SingleInstanceLock.acquire(path: CommandLine.arguments[2])
            exit(lock == nil ? 0 : 1)
        }

        var failures = 0
        func ok(_ name: String, _ cond: Bool, _ detail: String = "") {
            if cond { print("OK \(name)") }
            else {
                FileHandle.standardError.write(Data("FAIL \(name) \(detail)\n".utf8))
                failures += 1
            }
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipvault-lock-test-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(atPath: dir.path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lockPath = dir.appendingPathComponent("run/server.lock").path

        // A. Fresh path acquires; a second open+flock in the same process is refused.
        let first = SingleInstanceLock.acquire(path: lockPath)
        ok("acquire-fresh", first != nil)
        let second = SingleInstanceLock.acquire(path: lockPath)
        ok("second-acquire-refused", second == nil, "a live holder must block a second open()")
        ok("lock-file-records-owner", SingleInstanceLock.ownerPid(path: lockPath) == getpid())

        // B. Release frees it for the next owner.
        first?.release()
        let third = SingleInstanceLock.acquire(path: lockPath)
        ok("reacquire-after-release", third != nil)
        third?.release()

        // C. A stale file with no live holder must not block startup (crash recovery).
        FileManager.default.createFile(atPath: lockPath, contents: Data("pid=999999\n".utf8))
        let stale = SingleInstanceLock.acquire(path: lockPath)
        ok("stale-lock-reacquired", stale != nil, "flock, not the file, is the authority")
        stale?.release()

        // D. Real child process: while the parent holds it, the child must exit 0 (refused).
        let parentHold = SingleInstanceLock.acquire(path: lockPath)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--child", lockPath]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
            child.waitUntilExit()
            ok("child-process-refused", child.terminationStatus == 0,
               "child exited \(child.terminationStatus); a second server must not own the home")
        } catch {
            ok("child-process-refused", false, "spawn failed: \(error)")
        }
        parentHold?.release()

        // E. 64-way race: exactly one winner, no partial owners.
        let racePath = dir.appendingPathComponent("run/race.lock").path
        let guardLock = NSLock()
        var winners = 0
        var held: [SingleInstanceLock] = []
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if let l = SingleInstanceLock.acquire(path: racePath) {
                guardLock.lock()
                winners += 1
                held.append(l)
                guardLock.unlock()
            }
        }
        ok("race-single-winner", winners == 1, "expected 1 winner, got \(winners)")
        held.forEach { $0.release() }

        if failures > 0 {
            FileHandle.standardError.write(Data("single-instance: \(failures) failure(s)\n".utf8))
            exit(1)
        }
        print("single-instance: OK")
    }
}
