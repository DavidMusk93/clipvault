package com.davidmusk.keepsake.data

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.UUID

/**
 * Local-only capture queue for paste / share.
 * Mac backup remains the source of truth; phone captures live here until a future sync path.
 */
class CaptureQueueStore(context: Context) :
    SQLiteOpenHelper(context, "local_captures.db", null, 2) {

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE captures (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                text TEXT,
                html_content TEXT,
                content_hash TEXT NOT NULL,
                created_at_ms INTEGER NOT NULL,
                source TEXT NOT NULL
            )
            """.trimIndent()
        )
        db.execSQL("CREATE INDEX idx_cap_ts ON captures(created_at_ms DESC)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 2) {
            try {
                db.execSQL("ALTER TABLE captures ADD COLUMN html_content TEXT")
            } catch (_: Throwable) {
                // column may already exist on partial upgrades
            }
        }
    }

    suspend fun insertText(text: String, source: String): LocalCapture =
        insertCapture(CapturedClip(type = inferType(text), text = text, html = null), source)

    suspend fun insertCapture(clip: CapturedClip, source: String): LocalCapture =
        withContext(Dispatchers.IO) {
            val bytes = clip.text.toByteArray(Charsets.UTF_8)
            val hash = BackupRepository.sha256Hex(bytes)
            val row = LocalCapture(
                id = UUID.randomUUID().toString().uppercase(),
                type = clip.type.ifBlank { inferType(clip.text) },
                text = clip.text,
                htmlContent = clip.html,
                contentHash = hash,
                createdAtMs = System.currentTimeMillis(),
                source = source,
            )
            writableDatabase.insert(
                "captures",
                null,
                ContentValues().apply {
                    put("id", row.id)
                    put("type", row.type)
                    put("text", row.text)
                    put("html_content", row.htmlContent)
                    put("content_hash", row.contentHash)
                    put("created_at_ms", row.createdAtMs)
                    put("source", row.source)
                }
            )
            row
        }

    suspend fun list(limit: Int = 100): List<LocalCapture> = withContext(Dispatchers.IO) {
        readableDatabase.rawQuery(
            """
            SELECT id, type, text, content_hash, created_at_ms, source,
                   html_content
            FROM captures ORDER BY created_at_ms DESC LIMIT ?
            """.trimIndent(),
            arrayOf(limit.toString())
        ).use { c ->
            val out = ArrayList<LocalCapture>()
            val htmlIdx = try {
                c.getColumnIndexOrThrow("html_content")
            } catch (_: Throwable) {
                -1
            }
            while (c.moveToNext()) {
                out += LocalCapture(
                    id = c.getString(0),
                    type = c.getString(1),
                    text = c.getString(2),
                    contentHash = c.getString(3),
                    createdAtMs = c.getLong(4),
                    source = c.getString(5),
                    htmlContent = if (htmlIdx >= 0) c.getString(htmlIdx) else null,
                )
            }
            out
        }
    }

    suspend fun count(): Int = withContext(Dispatchers.IO) {
        readableDatabase.rawQuery("SELECT COUNT(*) FROM captures", null).use {
            if (it.moveToFirst()) it.getInt(0) else 0
        }
    }

    private fun inferType(text: String): String =
        if (text.startsWith("http://") || text.startsWith("https://")) "url" else "text"
}
