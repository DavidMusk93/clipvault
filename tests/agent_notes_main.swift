import Foundation

// Gates for AgentNotesAccess（P0 骨架）：开关解析、token 提取/常数比较、
// 文件 token 回退、agent 归因消洗。零依赖，单独 swiftc 编译。

@main
enum AgentNotesTests {
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

        // env 环境隔离：子进程无法改父进程 env，这里直接测不受 env 影响的纯函数，
        // enabled 的 env 分支由部署自检覆盖（curl 404/200 两态）。

        // presentedToken：Bearer 与 X-ClipVault-Token 两种携带。
        eq(
            "bearer",
            AgentNotesAccess.presentedToken(["authorization": "Bearer tok-123"]) ?? "",
            "tok-123"
        )
        eq(
            "header",
            AgentNotesAccess.presentedToken(["x-clipvault-token": "tok-123"]) ?? "",
            "tok-123"
        )
        ok("bearer-prefix-only", AgentNotesAccess.presentedToken(["authorization": "Bearer "]) == nil)
        ok("none", AgentNotesAccess.presentedToken([:]) == nil)
        eq(
            "header-wins",
            AgentNotesAccess.presentedToken(["x-clipvault-token": "a", "authorization": "Bearer b"]) ?? "",
            "a"
        )

        // timingEqual：等长逐字节；不等长直接 false。
        ok("timing-yes", AgentNotesAccess.timingEqual("clip-token", "clip-token"))
        ok("timing-no", !AgentNotesAccess.timingEqual("clip-token", "clip-tokeN"))
        ok("timing-len", !AgentNotesAccess.timingEqual("clip", "clip-token"))

        // authorize：无 token 真源 = 一律拒绝（fail closed）。
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-notes-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        ok("auth-no-token-source", !AgentNotesAccess.authorize(headers: ["authorization": "Bearer x"], dataRoot: tmp))

        // 文件 token 回退 + 0600 权限不被读取路径依赖。
        let tokenURL = tmp.appendingPathComponent("config/agent-token")
        try? FileManager.default.createDirectory(at: tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "tok-file-99\n".write(to: tokenURL, atomically: true, encoding: .utf8)
        ok("auth-file-ok", AgentNotesAccess.authorize(headers: ["authorization": "Bearer tok-file-99"], dataRoot: tmp))
        ok("auth-file-header", AgentNotesAccess.authorize(headers: ["x-clipvault-token": "tok-file-99"], dataRoot: tmp))
        ok("auth-file-wrong", !AgentNotesAccess.authorize(headers: ["authorization": "Bearer tok-file-98"], dataRoot: tmp))
        ok("auth-file-none", !AgentNotesAccess.authorize(headers: [:], dataRoot: tmp))

        // agent 归因消洗：小写 + 白名单字符 + 截断 + 兜底。
        eq("source", AgentNotesAccess.agentSource(name: "Pi"), "agent:pi")
        eq("source-clean", AgentNotesAccess.agentSource(name: " Grok#2 "), "agent:grok2")
        eq("source-dash", AgentNotesAccess.agentSource(name: "trae_hooks-x"), "agent:trae_hooks-x")
        eq("source-default", AgentNotesAccess.agentSource(name: nil), "agent:agent")
        eq("source-empty", AgentNotesAccess.agentSource(name: "  "), "agent:agent")
        eq("source-cjk", AgentNotesAccess.agentSource(name: "助手"), "agent:agent")
        eq(
            "source-trunc",
            AgentNotesAccess.agentSource(name: String(repeating: "a", count: 64)),
            "agent:" + String(repeating: "a", count: 32)
        )

        if fails > 0 {
            FileHandle.standardError.write(Data("agent_notes_main: \(fails) failure(s)\n".utf8))
            exit(1)
        }
        print("agent_notes_main: all passed")
    }
}
