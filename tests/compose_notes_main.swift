import Foundation

struct ClipboardItem {}
enum ArchiveImageInliner {
    static func isAssetSHA(_ sha: String) -> Bool { true }
}

@main
enum ComposeNotesNormalizeTests {
    static func main() {
        var fails = 0
        func eq(_ name: String, _ got: String, _ want: String) {
            if got == want { print("OK \(name)") }
            else {
                FileHandle.standardError.write(Data(
                    "FAIL \(name)\n  want: \(want.debugDescription)\n   got: \(got.debugDescription)\n".utf8
                ))
                fails += 1
            }
        }

        eq("title-sep", ComposeNotes.normalizedBody(title: "T", body: "hello"), "# T\n\nhello")
        eq("keep-trailing", ComposeNotes.normalizedBody(title: "T", body: "hello\n\n"), "# T\n\nhello\n\n")
        eq("keep-leading", ComposeNotes.normalizedBody(title: "T", body: "\nhello"), "# T\n\n\nhello")
        eq("empty-body", ComposeNotes.normalizedBody(title: "T", body: ""), "# T")
        eq("crlf-trailing", ComposeNotes.normalizedBody(title: "T", body: "hello\r\n\r\n"), "# T\n\nhello\n\n")
        eq("no-title", ComposeNotes.normalizedBody(title: nil, body: "hello\n\n"), "hello\n\n")
        eq("already-h1", ComposeNotes.normalizedBody(title: "T", body: "# T\n\nhello\n"), "# T\n\nhello\n")

        if fails > 0 { exit(1) }
        print("compose-notes: all passed")
    }
}
