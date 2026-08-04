package com.davidmusk.keepsake.data

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import android.provider.DocumentsContract
import android.util.Log
import androidx.documentfile.provider.DocumentFile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest

/**
 * Read Mac Keepsake backup layout via SAF tree URI:
 *
 *   {tree}/latest/clipflow.db
 *   {tree}/latest/MANIFEST.json
 *   {tree}/blobs/{hash}.bin | {hash}.rtf.bin | {hash}.pdf.bin
 *   {tree}/STATUS.json
 */
class BackupRepository(
    private val context: Context,
    private val prefs: Prefs,
) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val cacheDb: File get() = File(context.cacheDir, "clipflow_backup.db")

    data class SyncResult(
        val itemCount: Int,
        val sha256: String?,
        val manifest: BackupManifest?,
        val status: BackupStatusFile?,
        val message: String,
    )

    fun hasBackupRoot(): Boolean = prefs.backupTreeUri != null

    fun treeRoot(): DocumentFile? {
        val uri = prefs.backupTreeUri ?: return null
        return DocumentFile.fromTreeUri(context, uri)
    }

    suspend fun persistTreeUri(uri: Uri) = withContext(Dispatchers.IO) {
        val flags = android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or
            android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        try {
            context.contentResolver.takePersistableUriPermission(uri, flags)
        } catch (e: SecurityException) {
            // Read-only grant is enough for viewer
            try {
                context.contentResolver.takePersistableUriPermission(
                    uri,
                    android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (e2: SecurityException) {
                Log.w(TAG, "persist uri failed", e2)
            }
        }
        prefs.backupTreeUri = uri
    }

    suspend fun syncFromBackup(): SyncResult = withContext(Dispatchers.IO) {
        val treeUri = prefs.backupTreeUri
            ?: return@withContext SyncResult(0, null, null, null, "尚未选择云端文件夹")

        // Drive SAF: DocumentFile.findFile is unreliable. Use DocumentsContract children query.
        val latestId = findChildDocumentId(treeUri, parentDocId = null, displayName = "latest")
            ?: return@withContext SyncResult(
                0, null, null, null,
                "文件夹不对：请选中 Keepsake/backup（内含 latest）",
            )
        val dbUri = findChildDocumentUri(treeUri, parentDocId = latestId, displayName = "clipflow.db")
            ?: return@withContext SyncResult(
                0, null, null, null,
                "未找到记忆库 clipflow.db（latest/ 下）",
            )

        copyDocumentToFile(dbUri, cacheDb)

        val manifestUri = findChildDocumentUri(treeUri, parentDocId = latestId, displayName = "MANIFEST.json")
        val manifest = manifestUri?.let { readJsonDoc<BackupManifest>(it) }
        val statusUri = findChildDocumentUri(treeUri, parentDocId = null, displayName = "STATUS.json")
        val status = statusUri?.let { readJsonDoc<BackupStatusFile>(it) }
        val count = openDb()?.use { db ->
            db.rawQuery("SELECT COUNT(*) FROM clipboard_items", null).use { c ->
                if (c.moveToFirst()) c.getInt(0) else 0
            }
        } ?: 0

        prefs.lastSyncedSha = manifest?.sha256
        SyncResult(
            itemCount = count,
            sha256 = manifest?.sha256,
            manifest = manifest,
            status = status,
            message = "已载入 $count 条（Google Drive）"
        )
    }

    /**
     * List direct children of [parentDocId] inside a granted tree.
     * [parentDocId] null = tree root document.
     */
    private fun findChildDocumentId(
        treeUri: Uri,
        parentDocId: String?,
        displayName: String,
    ): String? {
        val treeDocId = try {
            DocumentsContract.getTreeDocumentId(treeUri)
        } catch (e: Exception) {
            Log.w(TAG, "not a tree uri: $treeUri", e)
            return null
        }
        val parentId = parentDocId ?: treeDocId
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
        return try {
            context.contentResolver.query(
                childrenUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                ),
                null,
                null,
                null,
            )?.use { c ->
                while (c.moveToNext()) {
                    val name = c.getString(1) ?: continue
                    val id = c.getString(0) ?: continue
                    Log.d(TAG, "child name=$name id=$id")
                    if (name.equals(displayName, ignoreCase = true)) return@use id
                }
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "list children failed parent=$parentId", e)
            // Fallback DocumentFile
            val root = DocumentFile.fromTreeUri(context, treeUri) ?: return null
            val parent = if (parentDocId == null) {
                root
            } else {
                // Walk is hard without ids; try root only
                root
            }
            parent.findFile(displayName)?.uri?.let {
                try {
                    DocumentsContract.getDocumentId(it)
                } catch (_: Exception) {
                    null
                }
            }
        }
    }

    private fun findChildDocumentUri(
        treeUri: Uri,
        parentDocId: String?,
        displayName: String,
    ): Uri? {
        val childId = findChildDocumentId(treeUri, parentDocId, displayName) ?: return null
        return DocumentsContract.buildDocumentUriUsingTree(treeUri, childId)
    }

    /** Resolve blobs/{name} under tree root for image payload. */
    fun findBlobUri(fileName: String): Uri? {
        val treeUri = prefs.backupTreeUri ?: return null
        val blobsId = findChildDocumentId(treeUri, parentDocId = null, displayName = "blobs")
            ?: return null
        return findChildDocumentUri(treeUri, parentDocId = blobsId, displayName = fileName)
    }

    suspend fun queryItems(limit: Int = 80, offset: Int = 0, q: String? = null): List<ClipboardRow> =
        withContext(Dispatchers.IO) {
            val db = openDb() ?: return@withContext emptyList()
            db.use {
                val hasQuery = !q.isNullOrBlank()
                val sql = if (hasQuery) {
                    """
                    SELECT id, timestamp, type, content_hash, text_content, url, html_content,
                           source_app, ocr_text, IFNULL(copy_count,1), file_urls
                    FROM clipboard_items
                    WHERE text_content LIKE ? OR ocr_text LIKE ? OR source_app LIKE ?
                          OR html_content LIKE ? OR url LIKE ?
                    ORDER BY timestamp DESC, id DESC
                    LIMIT ? OFFSET ?
                    """.trimIndent()
                } else {
                    """
                    SELECT id, timestamp, type, content_hash, text_content, url, html_content,
                           source_app, ocr_text, IFNULL(copy_count,1), file_urls
                    FROM clipboard_items
                    ORDER BY timestamp DESC, id DESC
                    LIMIT ? OFFSET ?
                    """.trimIndent()
                }
                val args = if (hasQuery) {
                    val like = "%${q!!.trim()}%"
                    arrayOf(like, like, like, like, like, limit.toString(), offset.toString())
                } else {
                    arrayOf(limit.toString(), offset.toString())
                }
                it.rawQuery(sql, args).use { c -> readRows(c) }
            }
        }

    suspend fun getItem(id: String): ClipboardRow? = withContext(Dispatchers.IO) {
        val db = openDb() ?: return@withContext null
        db.use {
            it.rawQuery(
                """
                SELECT id, timestamp, type, content_hash, text_content, url, html_content,
                       source_app, ocr_text, IFNULL(copy_count,1), file_urls
                FROM clipboard_items WHERE id = ? LIMIT 1
                """.trimIndent(),
                arrayOf(id)
            ).use { c -> readRows(c).firstOrNull() }
        }
    }

    /**
     * Load image/pdf/rtf bytes: prefer CAS under blobs/, fall back to inline BLOB columns.
     */
    suspend fun loadPayload(row: ClipboardRow): ByteArray? = withContext(Dispatchers.IO) {
        val candidates = when (row.type) {
            "image" -> listOf("${row.contentHash}.bin")
            "rtf" -> listOf("${row.contentHash}.rtf.bin", "${row.contentHash}.bin")
            "pdf" -> listOf("${row.contentHash}.pdf.bin", "${row.contentHash}.bin")
            else -> listOf("${row.contentHash}.bin")
        }
        for (name in candidates) {
            val uri = findBlobUri(name)
            if (uri != null) {
                val bytes = readAllBytes(uri)
                if (bytes != null && bytes.isNotEmpty()) return@withContext bytes
            }
        }
        // Inline legacy columns
        val col = when (row.type) {
            "image" -> "image_data"
            "rtf" -> "rtf_data"
            "pdf" -> "pdf_data"
            else -> null
        } ?: return@withContext null
        val db = openDb() ?: return@withContext null
        db.use {
            it.rawQuery("SELECT $col FROM clipboard_items WHERE id = ?", arrayOf(row.id)).use { c ->
                if (c.moveToFirst() && !c.isNull(0)) c.getBlob(0) else null
            }
        }
    }

    private fun openDb(): SQLiteDatabase? {
        if (!cacheDb.exists() || cacheDb.length() == 0L) return null
        return try {
            SQLiteDatabase.openDatabase(
                cacheDb.absolutePath,
                null,
                SQLiteDatabase.OPEN_READONLY
            )
        } catch (e: Exception) {
            Log.e(TAG, "open db failed", e)
            null
        }
    }

    private fun copyDocumentToFile(uri: Uri, dest: File) {
        dest.parentFile?.mkdirs()
        context.contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "无法打开 $uri" }
            FileOutputStream(dest).use { output -> input.copyTo(output) }
        }
    }

    private fun readAllBytes(uri: Uri): ByteArray? {
        return try {
            context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        } catch (e: Exception) {
            Log.e(TAG, "read blob failed", e)
            null
        }
    }

    private inline fun <reified T> readJsonDoc(uri: Uri): T? {
        return try {
            val text = context.contentResolver.openInputStream(uri)?.use { String(it.readBytes()) }
                ?: return null
            json.decodeFromString<T>(text)
        } catch (e: Exception) {
            Log.w(TAG, "json parse failed", e)
            null
        }
    }

    private fun readRows(c: android.database.Cursor): List<ClipboardRow> {
        val out = ArrayList<ClipboardRow>(c.count)
        // Column order must match SELECT list in queryItems/getItem.
        while (c.moveToNext()) {
            out += ClipboardRow(
                id = c.getString(0),
                timestamp = c.getDouble(1),
                type = c.getString(2),
                contentHash = c.getString(3),
                textContent = c.getString(4),
                url = c.getString(5),
                htmlContent = c.getString(6),
                sourceApp = c.getString(7),
                ocrText = c.getString(8),
                copyCount = c.getInt(9),
                fileUrls = c.getString(10),
            )
        }
        return out
    }

    companion object {
        private const val TAG = "BackupRepository"

        fun sha256Hex(bytes: ByteArray): String {
            val dig = MessageDigest.getInstance("SHA-256").digest(bytes)
            return dig.joinToString("") { "%02x".format(it) }
        }

        fun formatBytes(n: Long): String {
            if (n < 1024) return "$n B"
            if (n < 1024 * 1024) return "%.1f KB".format(n / 1024.0)
            return "%.1f MB".format(n / (1024.0 * 1024.0))
        }
    }
}
