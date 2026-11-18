import Foundation

// Gates for NoteTags：与 web 面板 extractNoteTags() 同语义（围栏、词界、去重）。

@main
enum NoteTagsTests {
    static func main() {
        var fails = 0
        func eq(_ name: String, _ got: [String], _ want: [String]) {
            if got == want { print("OK \(name)") }
            else {
                FileHandle.standardError.write(Data(
                    "FAIL \(name)\n  want: \(want)\n   got: \(got)\n".utf8
                ))
                fails += 1
            }
        }

        eq("basic", NoteTags.extract(from: "# t\n\n正文 #foo 结尾。"), ["foo"])
        eq("case-dedup-keeps-first", NoteTags.extract(from: "x #Foo y #foo z #FOO"), ["Foo"])
        eq("multiline", NoteTags.extract(from: "#a\n#b\n#c"), ["a", "b", "c"])
        eq("fence-skipped", NoteTags.extract(from: "#keep\n```\n#inside\n```\n#after"), ["keep", "after"])
        eq("fence-indent3", NoteTags.extract(from: "#keep\n   ```\n#inside\n   ```\n#after"), ["keep", "after"])
        eq("no-leading-bound", NoteTags.extract(from: "x#tag"), [])
        eq("cjk-prefix-ok", NoteTags.extract(from: "结尾#标签1"), ["标签1"])
        eq("word-prefix-blocked", NoteTags.extract(from: "abc#tag"), [])
        eq("underscore-prefix-blocked", NoteTags.extract(from: "a_b#tag"), [])
        eq("hash-prefix-blocked", NoteTags.extract(from: "##tag"), [])
        eq("adjacent-hash-blocked", NoteTags.extract(from: "#a#b"), ["a"])
        eq("nested-slash", NoteTags.extract(from: "#os/cc"), ["os/cc"])
        eq("dash-underscore", NoteTags.extract(from: "#a-b_c"), ["a-b_c"])
        eq("len33-truncated", NoteTags.extract(from: "#" + String(repeating: "a", count: 33) + "z"), [String(repeating: "a", count: 32)])
        eq("empty", NoteTags.extract(from: ""), [])
        eq("heading-not-tag", NoteTags.extract(from: "# 标题"), [])

        if fails > 0 {
            FileHandle.standardError.write(Data("note_tags_main: \(fails) failure(s)\n".utf8))
            exit(1)
        }
        print("note_tags_main: all passed")
    }
}
