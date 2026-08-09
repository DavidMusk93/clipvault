import Foundation

/// Human-facing instants for ClipVault wire/UI.
///
/// Rules:
/// 1. Absolute time on the wire as unix seconds (always correct).
/// 2. Human strings use a **stable display zone** (device current; never bare UTC `Z` alone).
/// 3. Prefer preformatted `timeLocal` in JSON so a browser stuck on UTC still shows wall clock.
enum ClipTimeFormat {
    /// Zone used for all user-visible wall clocks. Prefer system; if system is UTC, fall back to
    /// Asia/Shanghai (this product’s primary users). Keeps LaunchAgent / WebView edge cases honest.
    static var displayTimeZone: TimeZone {
        let cur = TimeZone.current
        if cur.secondsFromGMT() == 0,
           (cur.identifier == "UTC" || cur.identifier == "GMT" || cur.identifier == "GMT+0") {
            return TimeZone(identifier: "Asia/Shanghai") ?? cur
        }
        return cur
    }

    /// ISO-8601 with internet date-time + numeric offset (never bare Z-only when local ≠ UTC).
    static func isoLocal(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = displayTimeZone
        return f.string(from: date)
    }

    static func isoLocal(unix: Double) -> String {
        isoLocal(Date(timeIntervalSince1970: unix))
    }

    /// Compact local id for snapshot dirs: `yyyyMMdd-HHmmss` in display zone.
    static func localTimestampId(_ date: Date = Date()) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = displayTimeZone
        df.dateFormat = "yyyyMMdd-HHmmss"
        return df.string(from: date)
    }

    /// Wall clock for UI: `yyyy/MM/dd HH:mm:ss` (matches web cards).
    static func displayWall(_ date: Date = Date()) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = displayTimeZone
        df.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return df.string(from: date)
    }

    static func displayWall(unix: Double) -> String {
        displayWall(Date(timeIntervalSince1970: unix))
    }

    /// Legacy alias.
    static func localWall(_ date: Date = Date()) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = displayTimeZone
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df.string(from: date)
    }

    static var timeZoneId: String { displayTimeZone.identifier }
}
