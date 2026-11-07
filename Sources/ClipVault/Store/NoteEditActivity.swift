import Foundation

/// Note warmth is a projection of body history, never copy_count or evaluations.
/// Filter to the requested notes before windowing; the item/ts index bounds reads.
enum NoteEditActivity {
    /// One save is not one edit. Saves inside a quiet window belong to the same
    /// burst, and a burst only becomes an edit once nothing followed it for this
    /// long — otherwise autosave would inflate the count.
    static let burstQuiet: TimeInterval = 180

    /// Bind order: one `?` per note id, then the current epoch seconds used to
    /// decide whether the newest burst has already gone quiet.
    static func countSQL(placeholders: String) -> String {
        let quiet = Int(burstQuiet)
        return """
        WITH versions AS (
            SELECT id, item_id, ts, NULLIF(content_hash, '') AS version_hash,
                   LAG(NULLIF(content_hash, '')) OVER history AS previous_hash,
                   LAG(id) OVER history AS previous_id
            FROM compose_ops WHERE item_id IN (\(placeholders))
            WINDOW history AS (PARTITION BY item_id ORDER BY ts, id)
        ), changes AS (
            SELECT item_id, id, ts FROM versions v
            WHERE previous_id IS NOT NULL AND CASE
                WHEN version_hash IS NOT NULL AND previous_hash IS NOT NULL
                    THEN version_hash != previous_hash
                ELSE (SELECT body FROM compose_ops WHERE id = v.id)
                    != (SELECT body FROM compose_ops WHERE id = v.previous_id)
                END
        ), bursts AS (
            SELECT item_id, ts,
                   LAG(ts) OVER (PARTITION BY item_id ORDER BY ts, id) AS previous_ts
            FROM changes
        ), tally AS (
            SELECT item_id,
                   SUM(CASE WHEN previous_ts IS NULL OR ts - previous_ts > \(quiet)
                            THEN 1 ELSE 0 END) AS bursts,
                   MAX(ts) AS last_ts
            FROM bursts GROUP BY item_id
        )
        SELECT item_id,
               MAX(0, bursts - CASE WHEN ? - last_ts < \(quiet) THEN 1 ELSE 0 END)
        FROM tally;
        """
    }
}
