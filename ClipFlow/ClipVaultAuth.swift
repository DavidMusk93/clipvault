import Foundation
import CryptoKit
import CommonCrypto
import CoreImage
import AppKit

/// Public-host login: TOTP (Authenticator) + signed session cookie.
/// Loopback is never gated. Secret lives in KEEPSAKE_HOME/config (not git).
final class ClipVaultAuth {
    static let shared = ClipVaultAuth()
    static let cookieName = "clipvault_sess"
    static let sessionDays = 14

    private let lock = NSLock()
    private var secret: Data?
    private var failTimes: [TimeInterval] = []

    private init() {
        secret = Self.loadOrCreateSecret()
        if secret != nil {
            print("[Auth] TOTP ready. Pair Authenticator at http://127.0.0.1:8080/login/setup")
        }
    }

    func isSessionAuthorized(_ headers: [String: String]) -> Bool {
        if let jwt = headers["cf-access-jwt-assertion"], !jwt.isEmpty { return true }
        guard let cookie = cookieValue(headers["cookie"], name: Self.cookieName) else { return false }
        return verifySession(cookie)
    }

    func verifyCode(_ raw: String) -> Bool {
        let code = raw.filter(\.isNumber)
        guard code.count == 6, let secret else { return false }
        lock.lock()
        let now = Date().timeIntervalSince1970
        failTimes = failTimes.filter { now - $0 < 600 }
        if failTimes.count >= 8 {
            lock.unlock()
            return false
        }
        lock.unlock()
        let ok = Self.totpAccept(code, secret: secret, at: Date())
        if !ok {
            lock.lock()
            failTimes.append(now)
            lock.unlock()
        }
        return ok
    }

    func newSessionCookie() -> String {
        let exp = Int(Date().timeIntervalSince1970) + Self.sessionDays * 86400
        let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).map { String(format: "%02x", $0) }.joined()
        let payload = "\(exp).\(nonce)"
        let mac = hmacHex(payload)
        let value = "\(payload).\(mac)"
        return "\(Self.cookieName)=\(value); Path=/; Max-Age=\(Self.sessionDays * 86400); HttpOnly; Secure; SameSite=Lax"
    }

    func setupPageHTML() -> String {
        guard let secret else {
            return "<p>TOTP secret missing.</p>"
        }
        let b32 = Self.base32(secret)
        let url = "otpauth://totp/ClipVault:home?secret=\(b32)&issuer=ClipVault&digits=6&period=30"
        let qr = Self.qrPNGDataURL(url) ?? ""
        let img = qr.isEmpty ? "" : "<img alt=\"QR\" src=\"\(qr)\" width=\"220\" height=\"220\"/>"
        return """
        <!DOCTYPE html><html lang="zh-CN"><meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width,initial-scale=1"/>
        <title>ClipVault · 绑定 Authenticator</title>
        <style>
          body{font:16px/1.45 -apple-system,BlinkMacSystemFont,sans-serif;max-width:28rem;margin:3rem auto;padding:0 1.2rem;color:#1d1d1f}
          code{font:13px ui-monospace,Menlo,monospace;word-break:break-all}
          .box{background:#f5f5f7;border-radius:14px;padding:1rem 1.1rem;margin:1rem 0}
        </style>
        <h1>绑定 Authenticator</h1>
        <p>只在本机打开这一页。用 Google Authenticator / 1Password / 系统密码扫码，之后公网只输 6 位数字。</p>
        <div class="box">\(img)<p>密钥（备用手动输入）<br><code>\(b32)</code></p></div>
        <p><a href="/clipvault/login">去登录</a></p>
        """
    }

    func loginPageHTML(error: String?) -> String {
        let err = error.map { "<p style=\"color:#c41e3a\">\($0)</p>" } ?? ""
        return """
        <!DOCTYPE html><html lang="zh-CN"><meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width,initial-scale=1"/>
        <title>ClipVault</title>
        <style>
          body{font:16px/1.45 -apple-system,BlinkMacSystemFont,sans-serif;max-width:22rem;margin:18vh auto;padding:0 1.2rem;color:#1d1d1f}
          input{font:22px/1.2 ui-monospace,Menlo,monospace;letter-spacing:.28em;width:100%;box-sizing:border-box;padding:.7rem .8rem;border:1px solid #d2d2d7;border-radius:12px;text-align:center}
          button{margin-top:.8rem;width:100%;border:0;border-radius:12px;padding:.75rem;background:#1d1d1f;color:#fff;font:16px/1.2 -apple-system,sans-serif}
        </style>
        <h1>ClipVault</h1>
        <p>打开 Authenticator，输入 6 位验证码。</p>
        \(err)
        <form method="post" action="/clipvault/login" autocomplete="one-time-code">
          <input name="code" inputmode="numeric" pattern="[0-9]*" maxlength="6" autofocus required/>
          <button type="submit">进入</button>
        </form>
        """
    }

    // MARK: - session

    private func verifySession(_ value: String) -> Bool {
        let bits = value.split(separator: ".")
        guard bits.count == 3,
              let exp = Int(bits[0]),
              exp > Int(Date().timeIntervalSince1970) else { return false }
        let payload = "\(bits[0]).\(bits[1])"
        return Self.timingEq(hmacHex(payload), String(bits[2]))
    }

    private func hmacHex(_ payload: String) -> String {
        let key = sessionKey()
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    private func sessionKey() -> SymmetricKey {
        let seed = (secret ?? Data("clipvault".utf8)) + Data("clipvault-sess-v1".utf8)
        let digest = SHA256.hash(data: seed)
        return SymmetricKey(data: Data(digest))
    }

    private func cookieValue(_ cookie: String?, name: String) -> String? {
        guard let cookie else { return nil }
        for part in cookie.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces) == name {
                return String(kv[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - secret file

    private static func secretURL() -> URL {
        DatabaseManager.resolveDataRoot()
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("totp.secret")
    }

    private static func loadOrCreateSecret() -> Data? {
        let url = secretURL()
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let raw = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = base32Decode(trimmed), data.count >= 10 { return data }
        }
        var bytes = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let data = Data(bytes)
        let text = base32(data) + "\n"
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            print("[Auth] failed to write TOTP secret: \(error)")
            return nil
        }
        return data
    }

    // MARK: - TOTP

    static func totpAccept(_ code: String, secret: Data, at date: Date) -> Bool {
        let step: TimeInterval = 30
        let t = date.timeIntervalSince1970
        for w in [-1, 0, 1] {
            if Self.timingEq(totp(secret: secret, counter: UInt64(Int64(floor(t / step)) + Int64(w))), code) { return true }
        }
        return false
    }

    static func timingEq(_ a: String, _ b: String) -> Bool {
        let aa = Array(a.utf8)
        let bb = Array(b.utf8)
        guard aa.count == bb.count else { return false }
        var x: UInt8 = 0
        for i in aa.indices { x |= aa[i] ^ bb[i] }
        return x == 0
    }

    static func totp(secret: Data, counter: UInt64) -> String {
        var be = counter.bigEndian
        let msg = withUnsafeBytes(of: &be) { Data($0) }
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        secret.withUnsafeBytes { k in
            msg.withUnsafeBytes { m in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), k.baseAddress, secret.count, m.baseAddress, msg.count, &mac)
            }
        }
        let offset = Int(mac[19] & 0x0f)
        let bin = (UInt32(mac[offset] & 0x7f) << 24)
            | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8)
            | UInt32(mac[offset + 3])
        return String(format: "%06d", bin % 1_000_000)
    }

    static func base32(_ data: Data) -> String {
        let abc = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0
        var buf = 0
        var out = ""
        for b in data {
            buf = (buf << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(abc[(buf >> bits) & 31])
            }
        }
        if bits > 0 { out.append(abc[(buf << (5 - bits)) & 31]) }
        return out
    }

    static func base32Decode(_ s: String) -> Data? {
        let abc = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var map = [Character: Int]()
        for (i, c) in abc.enumerated() { map[c] = i }
        var bits = 0
        var buf = 0
        var bytes = [UInt8]()
        for ch in s.uppercased() where ch != "=" {
            guard let v = map[ch] else { return nil }
            buf = (buf << 5) | v
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buf >> bits) & 0xff))
            }
        }
        return Data(bytes)
    }

    static func qrPNGDataURL(_ text: String) -> String? {
        let data = Data(text.utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        guard let tiff = img.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
