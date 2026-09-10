import Foundation

/// CV01 origin frames. Browser never sees this socket; it is not HTTP.
enum OriginWire {
    static let magic = Data([0x43, 0x56, 0x30, 0x31]) // CV01
    static let streamLen: UInt32 = 0xFFFF_FFFF
    static let maxMeta = 256 * 1024
    static let maxBody = 8 * 1024 * 1024

    struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    static func appendU32(_ n: UInt32, to data: inout Data) {
        var be = n.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    static func readU32(_ data: Data, at: Int) -> UInt32? {
        guard at + 4 <= data.count else { return nil }
        return (UInt32(data[at]) << 24)
            | (UInt32(data[at + 1]) << 16)
            | (UInt32(data[at + 2]) << 8)
            | UInt32(data[at + 3])
    }

    static func encodeResponse(status: Int, headers: [(String, String)], body: Data, stream: Bool) -> Data {
        let hdrs = headers.map { [$0.0, $0.1] }
        var obj: [String: Any] = [
            "status": status,
            "headers": hdrs,
        ]
        if stream { obj["stream"] = true }
        let json = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        var out = Data()
        out.append(magic)
        appendU32(UInt32(json.count), to: &out)
        out.append(json)
        appendU32(stream ? streamLen : UInt32(body.count), to: &out)
        if !stream { out.append(body) }
        return out
    }

    /// Incomplete → nil. Bad magic / sizes → error request consumed as empty method.
    static func decodeRequest(from data: Data) -> (Request, Int)? {
        guard data.count >= 12 else { return nil }
        guard data.prefix(4) == magic else { return nil }
        guard let jlen32 = readU32(data, at: 4) else { return nil }
        let jlen = Int(jlen32)
        guard jlen > 0, jlen <= maxMeta else { return nil }
        guard data.count >= 12 + jlen else { return nil }
        guard let blen32 = readU32(data, at: 8 + jlen) else { return nil }
        if blen32 == streamLen { return nil }
        let blen = Int(blen32)
        guard blen >= 0, blen <= maxBody else { return nil }
        let total = 12 + jlen + blen
        guard data.count >= total else { return nil }
        let json = data.subdata(in: 8..<(8 + jlen))
        let body = data.subdata(in: (12 + jlen)..<total)
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            return (Request(method: "", path: "/", headers: [:], body: Data()), total)
        }
        let method = (obj["method"] as? String) ?? "GET"
        let path = (obj["path"] as? String) ?? "/"
        var headers: [String: String] = [:]
        if let pairs = obj["headers"] as? [[Any]] {
            for pair in pairs {
                guard pair.count >= 2,
                      let k = pair[0] as? String,
                      let v = pair[1] as? String else { continue }
                headers[k.lowercased()] = v
            }
        } else if let map = obj["headers"] as? [String: String] {
            for (k, v) in map { headers[k.lowercased()] = v }
        }
        return (Request(method: method, path: path, headers: headers, body: body), total)
    }

    static func looksLikeCV01(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4) == magic
    }
}
