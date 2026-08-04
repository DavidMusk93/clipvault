package com.davidmusk.keepsake.data

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.DocumentsContract
import android.util.Log
import androidx.documentfile.provider.DocumentFile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.Collections
import java.util.LinkedHashMap
import java.util.zip.ZipInputStream

/**
 * Read Mac Keepsake backup layout via SAF tree URI:
 *
 *   {tree}/latest/clipflow.db
 *   {tree}/latest/MANIFEST.json
 *   {tree}/blobs/{hash}.bin | {hash}.rtf.bin | {hash}.pdf.bin
 *   {tree}/STATUS.json
 *
 * Google Drive SAF is flaky for large `blobs/` listings and stream reopen.
 * Reliability stack:
 *  1) local disk CAS cache (filesDir/blob_cache)
 *  2) in-memory name→documentId index (one scan / session, rebuild on miss)
 *  3) download with retries; decode from local file (not live Drive stream)
 */
class BackupRepository(
    private val context: Context,
    private val prefs: Prefs,
) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val cacheDb: File get() = File(context.cacheDir, "clipflow_backup.db")
    private val blobCacheDir: File
        get() = File(context.filesDir, "blob_cache").also { it.mkdirs() }

    /** Tree URI string this index belongs to. */
    @Volatile private var indexTreeKey: String? = null
    @Volatile private var blobsFolderDocId: String? = null
    /** displayName → documentId under blobs/ (access-order LRU cap). */
    private val blobNameToDocId: MutableMap<String, String> =
        Collections.synchronizedMap(
            object : LinkedHashMap<String, String>(256, 0.75f, true) {
                override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>): Boolean =
                    size > BLOB_INDEX_MAX
            },
        )

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
        val prev = prefs.backupTreeUri
        prefs.backupTreeUri = uri
        if (prev?.toString() != uri.toString()) {
            invalidateBlobIndex()
        }
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

        try {
            copyDocumentAtomic(dbUri, cacheDb)
        } catch (e: Exception) {
            Log.e(TAG, "db download failed", e)
            return@withContext SyncResult(
                0, null, null, null,
                "下载记忆库失败：${e.message ?: "网络/权限"}，请稍后重试",
            )
        }

        // Prefer single-file pack of recent images (reliable vs listing blobs/* on Drive SAF).
        val packUri = findChildDocumentUri(treeUri, parentDocId = latestId, displayName = "cas_pack.zip")
        val packCount = packUri?.let { ingestCasPack(it) } ?: 0

        // New items may reference blobs not yet in our index (Drive lag).
        // Keep on-disk CAS cache; only drop name→id map so next image lookup rescan.
        blobsFolderDocId = null
        blobNameToDocId.clear()
        indexTreeKey = treeUri.toString()

        val manifestUri = findChildDocumentUri(treeUri, parentDocId = latestId, displayName = "MANIFEST.json")
        val manifest = manifestUri?.let { readJsonDoc<BackupManifest>(it) }
        val statusUri = findChildDocumentUri(treeUri, parentDocId = null, displayName = "STATUS.json")
        val status = statusUri?.let { readJsonDoc<BackupStatusFile>(it) }
        val count = openDb()?.use { db ->
            db.rawQuery("SELECT COUNT(*) FROM clipboard_items", null).use { c ->
                if (c.moveToFirst()) c.getInt(0) else 0
            }
        } ?: 0

        // Warm remaining recent hashes from blobs/ (best-effort; pack already covered many).
        val warmed = prefetchRecentBlobs(limit = 24)

        prefs.lastSyncedSha = manifest?.sha256 ?: status?.latest?.sha256
        prefs.lastAutoSyncAtMs = System.currentTimeMillis()
        val packNote = if (packCount > 0) "· 图包 $packCount" else ""
        val warmNote = if (warmed > 0) "· 预取 $warmed" else ""
        val msg = "已载入 $count 条（Google Drive）$packNote $warmNote".trim()
        prefs.lastAutoSyncMessage = msg
        SyncResult(
            itemCount = count,
            sha256 = manifest?.sha256,
            manifest = manifest,
            status = status,
            message = msg,
        )
    }

    /** Unzip Mac `latest/cas_pack.zip` into local blob_cache. Returns number of files written. */
    private fun ingestCasPack(packUri: Uri): Int {
        return try {
            var n = 0
            context.contentResolver.openInputStream(packUri)?.use { raw ->
                ZipInputStream(BufferedInputStream(raw)).use { zis ->
                    while (true) {
                        val entry = zis.nextEntry ?: break
                        try {
                            if (entry.isDirectory) continue
                            val name = File(entry.name).name
                            if (!name.endsWith(".bin") || name.contains("..")) continue
                            val safe = name.replace(Regex("[^A-Za-z0-9._-]"), "_")
                            val out = File(blobCacheDir, safe)
                            if (out.isFile && out.length() > 0L) continue
                            val tmp = File(blobCacheDir, "$safe.packtmp")
                            FileOutputStream(tmp).use { fos -> zis.copyTo(fos) }
                            if (out.exists()) out.delete()
                            if (!tmp.renameTo(out)) {
                                tmp.copyTo(out, overwrite = true)
                                tmp.delete()
                            }
                            if (out.isFile && out.length() > 0L) n++
                        } finally {
                            zis.closeEntry()
                        }
                    }
                }
            }
            Log.i(TAG, "cas_pack ingested files=$n")
            n
        } catch (e: Exception) {
            Log.w(TAG, "cas_pack ingest failed", e)
            0
        }
    }

    /** Best-effort download of recent image hashes into blob_cache. */
    private fun prefetchRecentBlobs(limit: Int): Int {
        val db = openDb() ?: return 0
        val names = mutableListOf<String>()
        db.use {
            it.rawQuery(
                """
                SELECT content_hash FROM clipboard_items
                WHERE type IN ('image','pdf','rtf')
                ORDER BY timestamp DESC LIMIT ?
                """.trimIndent(),
                arrayOf(limit.toString()),
            ).use { c ->
                while (c.moveToNext()) {
                    val h = c.getString(0) ?: continue
                    names += "$h.bin"
                    names += "$h.rtf.bin"
                    names += "$h.pdf.bin"
                }
            }
        }
        var ok = 0
        for (name in names.distinct()) {
            val local = File(blobCacheDir, name.replace(Regex("[^A-Za-z0-9._-]"), "_"))
            if (local.isFile && local.length() > 0L) {
                ok++
                continue
            }
            // Non-suspending path for sync thread: resolve + read once.
            val uri = resolveBlobDocumentUri(name, forceRescan = false) ?: continue
            val bytes = readAllBytesWithRetry(uri, attempts = 2) ?: continue
            if (bytes.isEmpty()) continue
            try {
                val tmp = File(blobCacheDir, "${local.name}.tmp")
                FileOutputStream(tmp).use { it.write(bytes) }
                if (local.exists()) local.delete()
                if (!tmp.renameTo(local)) {
                    tmp.copyTo(local, overwrite = true)
                    tmp.delete()
                }
                if (local.isFile && local.length() > 0L) ok++
            } catch (e: Exception) {
                Log.w(TAG, "prefetch write $name", e)
            }
        }
        Log.i(TAG, "prefetchRecentBlobs ok=$ok candidates=${names.size}")
        return ok
    }

    private fun invalidateBlobIndex() {
        indexTreeKey = null
        blobsFolderDocId = null
        blobNameToDocId.clear()
    }

    /**
     * Cheap fingerprint from STATUS.json / MANIFEST.json — no db download.
     * Used for change detection (auto-sync).
     */
    suspend fun peekRemoteFingerprint(): String? = withContext(Dispatchers.IO) {
        val treeUri = prefs.backupTreeUri ?: return@withContext null
        val statusUri = findChildDocumentUri(treeUri, parentDocId = null, displayName = "STATUS.json")
        statusUri?.let { readJsonDoc<BackupStatusFile>(it) }?.latest?.sha256?.let { return@withContext it }
        val latestId = findChildDocumentId(treeUri, parentDocId = null, displayName = "latest")
            ?: return@withContext null
        val manifestUri = findChildDocumentUri(treeUri, parentDocId = latestId, displayName = "MANIFEST.json")
        manifestUri?.let { readJsonDoc<BackupManifest>(it) }?.sha256
    }

    /**
     * Skip full db copy when remote sha matches [Prefs.lastSyncedSha].
     * Mature pattern for cloud folder readers (etag / content hash).
     */
    suspend fun syncIfChanged(force: Boolean = false): SyncResult = withContext(Dispatchers.IO) {
        if (!hasBackupRoot()) {
            return@withContext SyncResult(0, null, null, null, "尚未选择云端文件夹")
        }
        val remote = peekRemoteFingerprint()
        val local = prefs.lastSyncedSha
        if (!force && remote != null && remote == local && cacheDb.exists() && cacheDb.length() > 0) {
            val count = openDb()?.use { db ->
                db.rawQuery("SELECT COUNT(*) FROM clipboard_items", null).use { c ->
                    if (c.moveToFirst()) c.getInt(0) else 0
                }
            } ?: 0
            prefs.lastAutoSyncAtMs = System.currentTimeMillis()
            val msg = "已是最新 · $count 条"
            prefs.lastAutoSyncMessage = msg
            return@withContext SyncResult(count, remote, null, null, msg)
        }
        syncFromBackup()
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
                    if (name.equals(displayName, ignoreCase = true)) return@use id
                }
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "list children failed parent=$parentId", e)
            // Fallback DocumentFile (root-level only; Drive often fails nested findFile)
            val root = DocumentFile.fromTreeUri(context, treeUri) ?: return null
            if (parentDocId != null) return null
            root.findFile(displayName)?.uri?.let {
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

    private fun ensureTreeIndex(treeUri: Uri) {
        val key = treeUri.toString()
        if (indexTreeKey != key) {
            invalidateBlobIndex()
            indexTreeKey = key
        }
    }

    private fun ensureBlobsFolderId(treeUri: Uri): String? {
        ensureTreeIndex(treeUri)
        blobsFolderDocId?.let { return it }
        val id = findChildDocumentId(treeUri, parentDocId = null, displayName = "blobs")
        blobsFolderDocId = id
        return id
    }

    /**
     * Fill [blobNameToDocId] by listing blobs/.
     * Drive SAF is expensive — call only on cold start or lookup miss.
     * Tries paged queries when the provider supports OFFSET/LIMIT.
     */
    private fun scanBlobsFolder(treeUri: Uri, force: Boolean = false): Boolean {
        val blobsId = ensureBlobsFolderId(treeUri) ?: return false
        if (!force && blobNameToDocId.isNotEmpty()) return true
        if (force) blobNameToDocId.clear()
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, blobsId)
        return try {
            var n = 0
            var offset = 0
            val page = 200
            while (true) {
                val pageCount = queryChildrenPage(childrenUri, offset, page) { id, name ->
                    blobNameToDocId[name] = id
                    n++
                }
                if (pageCount < page) break
                offset += page
                if (offset > 10_000) break
            }
            if (n == 0) {
                val root = DocumentFile.fromTreeUri(context, treeUri)
                val blobsDir = root?.findFile("blobs")
                blobsDir?.listFiles()?.forEach { f ->
                    val name = f.name ?: return@forEach
                    val id = try {
                        DocumentsContract.getDocumentId(f.uri)
                    } catch (_: Exception) {
                        return@forEach
                    }
                    blobNameToDocId[name] = id
                    n++
                }
            }
            Log.i(TAG, "blob index size=$n map=${blobNameToDocId.size} (force=$force)")
            blobNameToDocId.isNotEmpty()
        } catch (e: Exception) {
            Log.e(TAG, "scan blobs/ failed", e)
            false
        }
    }

    private fun queryChildrenPage(
        childrenUri: Uri,
        offset: Int,
        limit: Int,
        onRow: (id: String, name: String) -> Unit,
    ): Int {
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        )
        val cursor = try {
            val args = android.os.Bundle().apply {
                putInt(android.content.ContentResolver.QUERY_ARG_LIMIT, limit)
                putInt(android.content.ContentResolver.QUERY_ARG_OFFSET, offset)
            }
            context.contentResolver.query(childrenUri, projection, args, null)
        } catch (_: Exception) {
            if (offset > 0) return 0
            context.contentResolver.query(childrenUri, projection, null, null, null)
        } ?: return 0
        var count = 0
        cursor.use { c ->
            while (c.moveToNext()) {
                val id = c.getString(0) ?: continue
                val name = c.getString(1) ?: continue
                onRow(id, name)
                count++
            }
        }
        return count
    }

    private fun resolveBlobDocumentUri(fileName: String, forceRescan: Boolean = false): Uri? {
        val treeUri = prefs.backupTreeUri ?: return null
        ensureTreeIndex(treeUri)

        if (!forceRescan) {
            blobNameToDocId[fileName]?.let { docId ->
                return DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
            }
        }

        val blobsId = ensureBlobsFolderId(treeUri)
        if (blobsId != null) {
            for (candidate in candidateDocIds(blobsId, fileName)) {
                val uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, candidate)
                if (probeReadable(uri)) {
                    blobNameToDocId[fileName] = candidate
                    return uri
                }
            }
        }

        scanBlobsFolder(treeUri, force = forceRescan || blobNameToDocId.isEmpty())
        blobNameToDocId[fileName]?.let { docId ->
            return DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
        }

        if (blobsId != null) {
            val id = findChildDocumentId(treeUri, parentDocId = blobsId, displayName = fileName)
            if (id != null) {
                blobNameToDocId[fileName] = id
                return DocumentsContract.buildDocumentUriUsingTree(treeUri, id)
            }
        }
        return null
    }

    private fun candidateDocIds(blobsFolderId: String, fileName: String): List<String> {
        return listOf(
            "$blobsFolderId/$fileName",
            "$blobsFolderId:$fileName",
            "${blobsFolderId.trimEnd('/')}/$fileName",
        )
    }

    private fun probeReadable(uri: Uri): Boolean {
        return try {
            context.contentResolver.openInputStream(uri)?.use { ins ->
                val buf = ByteArray(8)
                ins.read(buf) > 0
            } == true
        } catch (_: Exception) {
            false
        }
    }

    /** Resolve blobs/{name} under tree root for image payload. */
    fun findBlobUri(fileName: String): Uri? = resolveBlobDocumentUri(fileName, forceRescan = false)

    /**
     * Ensure blob bytes are on local disk (CAS cache). Retries Drive open on transient fail.
     * Returns local file or null.
     */
    suspend fun materializeBlob(fileName: String): File? = withContext(Dispatchers.IO) {
        val safe = fileName.replace(Regex("[^A-Za-z0-9._-]"), "_")
        val local = File(blobCacheDir, safe)
        if (local.isFile && local.length() > 0L) return@withContext local

        var lastError: Exception? = null
        repeat(BLOB_FETCH_ATTEMPTS) { attempt ->
            try {
                val uri = resolveBlobDocumentUri(
                    fileName,
                    forceRescan = attempt > 0,
                )
                if (uri == null) {
                    // Cloud lag: db may list a hash before Drive lists the blob.
                    delay(BLOB_RETRY_BASE_MS * (attempt + 1))
                    if (attempt == 1) {
                        // Hard refresh folder id + index
                        blobsFolderDocId = null
                        blobNameToDocId.clear()
                    }
                    return@repeat
                }
                val bytes = readAllBytesWithRetry(uri) ?: run {
                    delay(BLOB_RETRY_BASE_MS * (attempt + 1))
                    return@repeat
                }
                if (bytes.isEmpty()) return@repeat
                val tmp = File(blobCacheDir, "$safe.tmp")
                FileOutputStream(tmp).use { it.write(bytes) }
                if (local.exists()) local.delete()
                if (!tmp.renameTo(local)) {
                    tmp.copyTo(local, overwrite = true)
                    tmp.delete()
                }
                if (local.isFile && local.length() > 0L) return@withContext local
            } catch (e: Exception) {
                lastError = e
                Log.w(TAG, "materialize attempt ${attempt + 1} failed for $fileName", e)
                delay(BLOB_RETRY_BASE_MS * (attempt + 1))
            }
        }
        if (lastError != null) {
            Log.e(TAG, "materialize gave up $fileName", lastError)
        } else {
            Log.w(TAG, "blob not found after retries: $fileName")
        }
        null
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

    private fun blobCandidateNames(row: ClipboardRow): List<String> = when (row.type.lowercase()) {
        "image" -> listOf("${row.contentHash}.bin")
        "rtf" -> listOf("${row.contentHash}.rtf.bin", "${row.contentHash}.bin")
        "pdf" -> listOf("${row.contentHash}.pdf.bin", "${row.contentHash}.bin")
        else -> listOf("${row.contentHash}.bin")
    }

    /**
     * Load image/pdf/rtf bytes: local CAS cache → Drive blobs/ (retry) → inline BLOB columns.
     */
    suspend fun loadPayload(row: ClipboardRow): ByteArray? = withContext(Dispatchers.IO) {
        for (name in blobCandidateNames(row)) {
            val file = materializeBlob(name)
            if (file != null) {
                return@withContext try {
                    file.readBytes()
                } catch (e: Exception) {
                    Log.e(TAG, "read cache $name", e)
                    null
                }
            }
        }
        // Inline legacy columns
        val col = when (row.type.lowercase()) {
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

    /**
     * Decode image for UI without OOM.
     * Prefers local blob file (stable mark/reset) over live Drive streams.
     */
    suspend fun loadImageBitmap(
        row: ClipboardRow,
        maxSidePx: Int = 1600,
    ): android.graphics.Bitmap? = withContext(Dispatchers.IO) {
        val target = maxSidePx.coerceIn(64, 4096)
        for (name in blobCandidateNames(row)) {
            val file = materializeBlob(name)
            if (file != null) {
                decodeSampledFromFile(file, target)?.let { return@withContext it }
            }
        }
        val bytes = loadPayload(row) ?: return@withContext null
        decodeSampledFromBytes(bytes, target)
    }

    private fun decodeSampledFromFile(file: File, maxSidePx: Int): android.graphics.Bitmap? {
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, bounds)
            val sample = sampleSizeFor(bounds.outWidth, bounds.outHeight, maxSidePx)
            val opts = BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = android.graphics.Bitmap.Config.ARGB_8888
                inScaled = false
            }
            val raw = BitmapFactory.decodeFile(file.absolutePath, opts) ?: return null
            scaleDownIfNeeded(raw, maxSidePx)
        } catch (e: Exception) {
            Log.e(TAG, "decode file failed ${file.name}", e)
            null
        }
    }

    private fun decodeSampledFromUri(uri: Uri, maxSidePx: Int): android.graphics.Bitmap? {
        // Prefer single-read: Drive streams often fail on second open.
        return try {
            val bytes = readAllBytesWithRetry(uri) ?: return null
            decodeSampledFromBytes(bytes, maxSidePx)
        } catch (e: Exception) {
            Log.e(TAG, "decode uri failed $uri", e)
            null
        }
    }

    private fun decodeSampledFromBytes(bytes: ByteArray, maxSidePx: Int): android.graphics.Bitmap? {
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            val sample = sampleSizeFor(bounds.outWidth, bounds.outHeight, maxSidePx)
            val opts = BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = android.graphics.Bitmap.Config.ARGB_8888
                inScaled = false
            }
            val raw = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts) ?: return null
            scaleDownIfNeeded(raw, maxSidePx)
        } catch (e: Exception) {
            Log.e(TAG, "decode bytes failed", e)
            null
        }
    }

    /** Power-of-2 sample stays ≥ maxSide so final filter pass does the precise shrink. */
    private fun sampleSizeFor(w: Int, h: Int, maxSide: Int): Int {
        if (w <= 0 || h <= 0) return 1
        var sample = 1
        // Keep decoded size roughly ≤ 2× target to avoid huge intermediate bitmaps
        // while leaving headroom for filtered downscale (sharper than pure sample).
        val limit = maxSide * 2
        while (w / (sample * 2) >= limit || h / (sample * 2) >= limit) sample *= 2
        return sample.coerceAtLeast(1)
    }

    private fun scaleDownIfNeeded(
        src: android.graphics.Bitmap,
        maxSide: Int,
    ): android.graphics.Bitmap {
        val w = src.width
        val h = src.height
        val longSide = maxOf(w, h)
        if (longSide <= maxSide || longSide <= 0) return src
        val scale = maxSide.toFloat() / longSide.toFloat()
        val nw = (w * scale).toInt().coerceAtLeast(1)
        val nh = (h * scale).toInt().coerceAtLeast(1)
        return try {
            val scaled = android.graphics.Bitmap.createScaledBitmap(src, nw, nh, /* filter */ true)
            if (scaled !== src && !src.isRecycled) src.recycle()
            scaled
        } catch (e: Exception) {
            Log.w(TAG, "scaleDown failed, using sample bitmap", e)
            src
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

    /** Download to temp then rename so a partial db never replaces a good cache. */
    private fun copyDocumentAtomic(uri: Uri, dest: File) {
        dest.parentFile?.mkdirs()
        val tmp = File(dest.absolutePath + ".downloading")
        if (tmp.exists()) tmp.delete()
        context.contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "无法打开 $uri" }
            FileOutputStream(tmp).use { output -> input.copyTo(output) }
        }
        require(tmp.length() > 0L) { "空文件: $uri" }
        // Quick SQLite header check (db) or generic non-empty
        if (dest.name.endsWith(".db", ignoreCase = true)) {
            val hdr = ByteArray(16)
            val n = tmp.inputStream().use { it.read(hdr) }
            val ok = n >= 15 && String(hdr, 0, n.coerceAtLeast(0), Charsets.UTF_8)
                .startsWith("SQLite format 3")
            require(ok) { "不是有效的 SQLite 库" }
            SQLiteDatabase.openDatabase(tmp.absolutePath, null, SQLiteDatabase.OPEN_READONLY).close()
        }
        if (dest.exists()) dest.delete()
        if (!tmp.renameTo(dest)) {
            tmp.copyTo(dest, overwrite = true)
            tmp.delete()
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

    private fun readAllBytesWithRetry(uri: Uri, attempts: Int = 3): ByteArray? {
        var last: Exception? = null
        repeat(attempts) { i ->
            try {
                val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                if (bytes != null && bytes.isNotEmpty()) return bytes
            } catch (e: Exception) {
                last = e
                Log.w(TAG, "read attempt ${i + 1} failed $uri", e)
            }
            try {
                Thread.sleep(BLOB_RETRY_BASE_MS * (i + 1L))
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return null
            }
        }
        if (last != null) Log.e(TAG, "read gave up $uri", last)
        return null
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
        private const val BLOB_INDEX_MAX = 8000
        private const val BLOB_FETCH_ATTEMPTS = 3
        private const val BLOB_RETRY_BASE_MS = 350L

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
