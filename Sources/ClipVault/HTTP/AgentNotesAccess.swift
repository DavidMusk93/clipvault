import Foundation

/// Agent notes API gate（P0 骨架）。
///
/// `/api/notes*` 路由族只在 `CLIPVAULT_AGENT_API=1` 时存在（关闭 = 404，
/// 其余端点行为不变）。鉴权是独立 token：`CLIPVAULT_AGENT_TOKEN` env 优先，
/// 否则 `$CLIPVAULT_HOME/config/agent-token`（0600），以
/// `Authorization: Bearer <token>` 或 `X-ClipVault-Token: <token>` 携带。
/// 每次写入归因 `source = "agent:<name>"` 且只经 `saveComposeNote()` 唯一管线。
///
/// 本文件保持零依赖，供 `tests/agent_notes_main.swift` 单独 swiftc 编译。
enum AgentNotesAccess {
    static let envFlag = "CLIPVAULT_AGENT_API"
    static let envToken = "CLIPVAULT_AGENT_TOKEN"
    static let tokenFile = "config/agent-token"

    /// 开关：只有字面 "1" 打开。任何其它值（含未设置）= 关闭。
    static var enabled: Bool {
        (ProcessInfo.processInfo.environment[envFlag] ?? "") == "1"
    }

    /// 校验请求头里的 token。token 缺失（env 与文件都没有）= 一律拒绝。
    static func authorize(headers: [String: String], dataRoot: URL?) -> Bool {
        guard let token = loadToken(dataRoot: dataRoot), !token.isEmpty else { return false }
        guard let presented = presentedToken(headers), !presented.isEmpty else { return false }
        return timingEqual(presented, token)
    }

    /// 从请求头提取 agent 声明的 token。
    static func presentedToken(_ headers: [String: String]) -> String? {
        if let v = headers["x-clipvault-token"], !v.isEmpty { return v }
        let auth = headers["authorization"] ?? ""
        if auth.hasPrefix("Bearer "), auth.count > 7 {
            return String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// token 真源：env `CLIPVAULT_AGENT_TOKEN` 优先，否则 config/agent-token 文件。
    static func loadToken(dataRoot: URL?) -> String? {
        if let env = ProcessInfo.processInfo.environment[envToken] {
            let t = env.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        guard let dataRoot else { return nil }
        let url = dataRoot.appendingPathComponent(tokenFile)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 归因字符串：`agent:<name>`，name 消洗为小写 [a-z0-9-_]，≤32，兜底 "agent"。
    static func agentSource(name: String?) -> String {
        "agent:\(sanitizeAgentName(name))"
    }

    static func sanitizeAgentName(_ raw: String?) -> String {
        guard var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return "agent"
        }
        name = String(name.lowercased().prefix(32))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        let scalars = name.unicodeScalars.filter { allowed.contains($0) }
        let cleaned = String(String.UnicodeScalarView(scalars))
        return cleaned.isEmpty ? "agent" : cleaned
    }

    /// 常数时间比较（等长才逐字节；长度不等直接 false 不泄漏前缀信息）。
    static func timingEqual(_ a: String, _ b: String) -> Bool {
        let aa = Array(a.utf8)
        let bb = Array(b.utf8)
        guard aa.count == bb.count else { return false }
        var x: UInt8 = 0
        for i in aa.indices { x |= aa[i] ^ bb[i] }
        return x == 0
    }
}
