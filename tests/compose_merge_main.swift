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

        let leftEdit = "hello\nL\nworld\n"
        let rightEdit = "hello\nR\nworld\n"
        var wrapped = ComposeMerge.both(leftEdit, rightEdit).body
        ok("both-marks", ComposeMerge.hasConflictMarkers(wrapped))
        for i in 0..<12 {
            wrapped = ComposeMerge.both(wrapped, "hello\nR\(i)\nworld\n").body
        }
        ok("both-not-explode", !ComposeMerge.isExploded(wrapped))
        ok("both-bounded", wrapped.count < 400)

        var nest = "# title\nbody\n"
        for i in 0..<8 {
            nest = ComposeMerge.both(nest, "# title\nbody\n" + String(repeating: "x", count: i + 1) + "\n").body
        }
        ok("same-title-not-explode", !ComposeMerge.isExploded(nest))
        ok("same-title-keeps-latest", nest.contains("xxxxxxxx") && nest.count < 80)

        let exploded = (0..<6).reduce(into: "# note\nv\n") { acc, i in
            acc = "<<<<<<< \(i)\n\(acc)\n=======\n# note\n" + String(repeating: "v", count: i + 2) + "\n>>>>>>> \(i)\n"
        }
        ok("detect-exploded", ComposeMerge.isExploded(exploded))
        let recovered = ComposeMerge.flatten(exploded)
        ok("flatten-not-exploded", !ComposeMerge.isExploded(recovered.body))
        ok("flatten-keeps-latest", recovered.body.contains("vvvvvvv") && !recovered.conflict)

        if fails > 0 { exit(1) }
        print("compose-merge: all passed")
    }
}
