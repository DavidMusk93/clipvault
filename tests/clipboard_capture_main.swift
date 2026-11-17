import Foundation
import AppKit

@main
enum ClipboardCaptureTests {
    static func main() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("clipvault-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let empty = NSPasteboard.PasteboardType("org.clipvault.test.empty")
        let custom = NSPasteboard.PasteboardType("org.clipvault.test.custom")
        board.declareTypes([empty, custom], owner: nil)
        precondition(board.setData(Data(), forType: empty))
        precondition(board.setData(Data([42]), forType: custom))
        let selected = ClipboardCapturePolicy.firstNonempty([empty, custom]) { board.data(forType: $0) }
        precondition(selected?.0 == custom && selected?.1 == Data([42]), "skip empty flavor and preserve later data")
        precondition(ClipboardCapturePolicy.firstNonempty([empty]) { board.data(forType: $0) } == nil, "empty-only is not a capture")
        let payload = RawClipboardPayload(type: custom.rawValue, data: selected!.1)
        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(RawClipboardPayload.self, from: encoded)
        precondition(encoded.count > 16 && decoded == payload, "small opaque data and type survive encoding")
        let count = board.changeCount
        let stable = ClipboardCapturePolicy.stable(expected: count, current: { board.changeCount }) { selected }
        precondition(stable?.1 == Data([42]), "stable snapshot is accepted")
        let changed = ClipboardCapturePolicy.stable(expected: count, current: { board.changeCount }) {
            board.clearContents()
            return selected
        }
        precondition(changed == nil, "changed snapshot is rejected")
        precondition(ClipboardCapturePolicy.stable(expected: count, current: { board.changeCount }, read: { selected }) == nil, "stale work is rejected")
        precondition(BlobCAS.storageKey(String(repeating: "ab", count: 32) + ".raw") != nil, "raw CAS key supported")
        print("clipboard capture: all passed")
    }
}
