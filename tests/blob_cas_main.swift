import Foundation

@main
enum BlobCASTests {
    static func main() {
        var fails = 0
        func ok(_ name: String, _ cond: Bool) {
            if cond { print("OK \(name)") }
            else {
                FileHandle.standardError.write(Data("FAIL \(name)\n".utf8))
                fails += 1
            }
        }
        let sha = String(repeating: "ab", count: 32)
        ok("bare-sha", BlobCAS.storageKey(sha) == sha)
        ok("rtf-typed", BlobCAS.storageKey(sha + ".rtf") == sha + ".rtf")
        ok("pdf-typed", BlobCAS.storageKey(sha + ".pdf") == sha + ".pdf")
        ok("upper-hex", BlobCAS.storageKey(sha.uppercased()) == sha)
        ok("reject-short", BlobCAS.storageKey(String(sha.dropLast())) == nil)
        ok("reject-path", BlobCAS.storageKey("../" + sha) == nil)
        ok("reject-extra", BlobCAS.storageKey(sha + ".rtf.bin") == nil)
        ok("reject-empty", BlobCAS.storageKey("") == nil)
        if fails > 0 { exit(1) }
        print("blob-cas: all passed")
    }
}
