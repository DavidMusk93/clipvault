import Foundation

/// Wall order is **capture time**. One clock rewrite and the user's timeline is gone.
///
/// - `timestamp` = when the clip was copied (origin wall_ts / local recopy)
/// - `first_seen_at` = when this host first learned of the row
/// - OCR / replica `upsert` must not bump `timestamp` and must not emit `wall_ts = Date()`
/// - Only `kind=touch` (peer recopied the same body) may bump
enum WallClockPolicy {
    static let restoreMetaKey = "wall.restore_capture_ts_v1"

    static func bumpTimestamp(forKind kind: String) -> Bool {
        kind == "touch"
    }

    /// Derived follow-ups (OCR) reuse the row's capture clock. Nil → do not emit.
    static func wallTsForDerivedOp(captureTs: Double?) -> Double? {
        captureTs
    }

    /// copy_count=1 never recopied: a later timestamp is OCR/sync-clock damage.
    static func shouldRestoreToFirstSeen(timestamp: Double, firstSeenAt: Double?, copyCount: Int) -> Bool {
        guard copyCount <= 1, let seen = firstSeenAt else { return false }
        return timestamp > seen + 0.5
    }

    /// Exclusive keyset: strictly older than `(cursorTs, cursorId)` in DESC `(ts, id)` order.
    static func isOlderThanCursor(ts: Double, id: String, cursorTs: Double, cursorId: String) -> Bool {
        ts < cursorTs || (ts == cursorTs && id < cursorId)
    }
}
