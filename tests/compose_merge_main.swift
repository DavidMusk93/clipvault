import Foundation

@main
enum ComposeMergeTests {
    static func main() {
        var fails = 0
        func ok(_ name: String, _ cond: Bool) {
            if cond { print("OK \(name)") }
            else {
                FileHandle.standardError.write(Data("FAIL \(name)\n".utf8))
                fails += 1
            }
        }
        func eq(_ name: String, _ got: String, _ want: String) {
            if got == want { print("OK \(name)") }
            else {
                FileHandle.standardError.write(Data(
                    "FAIL \(name)\n  want: \(want.debugDescription)\n   got: \(got.debugDescription)\n".utf8
                ))
                fails += 1
            }
        }

        let base = "hello\nworld\n"
        eq("ff-a", ComposeMerge.threeWay(base: base, a: base, b: "hello\nworld\nthere\n").body, "hello\nworld\nthere\n")
        eq("ff-b", ComposeMerge.threeWay(base: base, a: "hello\nworld\nthere\n", b: base).body, "hello\nworld\nthere\n")
        eq("same", ComposeMerge.threeWay(base: base, a: "x\n", b: "x\n").body, "x\n")

        let left = "hello\nA\nworld\n"
        let right = "hello\nworld\nB\n"
        let ab = ComposeMerge.threeWay(base: base, a: left, b: right)
        let ba = ComposeMerge.threeWay(base: base, a: right, b: left)
        ok("clean", !ab.conflict)
        eq("clean-body", ab.body, "hello\nA\nworld\nB\n")
        eq("commutative", ab.body, ba.body)

        let c1 = ComposeMerge.threeWay(base: base, a: "hello\nL\nworld\n", b: "hello\nR\nworld\n")
        let c2 = ComposeMerge.threeWay(base: base, a: "hello\nR\nworld\n", b: "hello\nL\nworld\n")
        ok("conflict", c1.conflict)
        eq("conflict-commute", c1.body, c2.body)
        ok("markers", ComposeMerge.hasConflictMarkers(c1.body))
        ok("sorted-markers", c1.body.contains("<<<<<<< "))

        let once = ComposeMerge.threeWay(base: base, a: left, b: right).body
        let again = ComposeMerge.threeWay(base: base, a: once, b: right)
        ok("idempotent-right", !again.conflict && again.body == once)

        if fails > 0 { exit(1) }
        print("compose-merge: all passed")
    }
}
