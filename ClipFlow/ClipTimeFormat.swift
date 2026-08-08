import Foundation

/// Human-facing instants for ClipVault wire/UI.
/// Prefer **local wall clock with numeric offset** (`…+08:00`) over bare UTC `…Z`,
/// so STATUS/MANIFEST JSON and any unconverted UI still match the user's clock.
enum ClipTimeFormat {
    /// ISO-8601 with internet date-time + timezone offset from `TimeZone.current`.
    static func isoLocal(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }

    static func isoLocal(unix: Double) -> String {
        isoLocal(Date(timeIntervalSince1970: unix))
    }

    /// Compact local id for snapshot dirs: `yyyyMMdd-HHmmss` in local zone.
    static func localTimestampId(_ date: Date = Date()) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyyMMdd-HHmmss"
        return df.string(from: date)
    }

    /// Local wall clock for native UI / logs: `yyyy-MM-dd HH:mm:ss`.
    static func localWall(_ date: Date = Date()) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df.string(from: date)
    }
}
