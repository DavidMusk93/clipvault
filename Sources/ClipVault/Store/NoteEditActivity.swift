import Foundation

/// Note warmth is a projection of body history, never copy_count or evaluations.
/// Filter to the requested notes before windowing; the item/ts index bounds reads.
enum NoteEditActivity {
    static func countSQL(placeholders: String) -> String {
        """
        WITH versions AS (
            SELECT id, item_id, NULLIF(content_hash, '') AS version_hash,
                   LAG(NULLIF(content_hash, '')) OVER history AS previous_hash,
                   LAG(id) OVER history AS previous_id
            FROM compose_ops WHERE item_id IN (\(placeholders))
            WINDOW history AS (PARTITION BY item_id ORDER BY ts, id)
        )
        SELECT item_id, COUNT(*) FROM versions v
        WHERE previous_id IS NOT NULL AND CASE
            WHEN version_hash IS NOT NULL AND previous_hash IS NOT NULL
                THEN version_hash != previous_hash
            ELSE (SELECT body FROM compose_ops WHERE id = v.id)
                != (SELECT body FROM compose_ops WHERE id = v.previous_id)
            END
        GROUP BY item_id;
        """
    }
}
