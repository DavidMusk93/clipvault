package com.davidmusk.keepsake.data

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.util.Log

/**
 * Land OPEN_DOCUMENT_TREE on Google Drive — not local storage.
 *
 * MIUI DocumentsUI ignores vague INITIAL_URI and hides the roots drawer behind
 * a gesture that collides with system-back. We query Drive's DocumentsProvider
 * for the real document id of My Drive / Keepsake / backup, then pass that URI.
 */
object DriveTreePicker {
    const val DRIVE_PKG = "com.google.android.apps.docs"
    const val DRIVE_AUTHORITY = "com.google.android.apps.docs.storage"
    const val DRIVE_AUTHORITY_LEGACY = "com.google.android.apps.docs.storage.legacy"
    private const val TAG = "DriveTreePicker"

    fun isDriveInstalled(context: Context): Boolean {
        return try {
            context.packageManager.getPackageInfo(DRIVE_PKG, 0)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
    }

    /**
     * Best INITIAL_URI: prefer …/Keepsake/backup document, else My Drive root, else generic root.
     * Safe to call on a background thread (does ContentResolver queries).
     */
    fun bestInitialUri(context: Context): Uri? {
        if (!isDriveInstalled(context)) return null
        val resolver = context.contentResolver
        for (auth in listOf(DRIVE_AUTHORITY, DRIVE_AUTHORITY_LEGACY)) {
            try {
                val backup = findBackupDocumentUri(resolver, auth)
                if (backup != null) {
                    Log.i(TAG, "found backup doc uri=$backup")
                    return backup
                }
                val myDrive = findMyDriveRootDocumentUri(resolver, auth)
                if (myDrive != null) {
                    Log.i(TAG, "found mydrive uri=$myDrive")
                    return myDrive
                }
            } catch (e: Exception) {
                Log.w(TAG, "probe $auth failed: ${e.message}")
            }
        }
        // Last-resort static candidates (some OEMs only accept these forms)
        return staticRootCandidates().firstOrNull().also {
            Log.i(TAG, "fallback static uri=$it")
        }
    }

    /** Prefer AOSP/Google DocumentsUI — MIUI often hijacks OPEN_DOCUMENT_TREE with search apps. */
    private val DOCUMENTS_UI_CANDIDATES = listOf(
        "com.google.android.documentsui",
        "com.android.documentsui",
    )

    fun openTreeIntent(context: Context, initial: Uri? = null): Intent {
        return Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
            )
            val uri = initial ?: bestInitialUri(context)
            if (uri != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, uri)
            }
            // Pin handler so "Complete action using Baidu/…" never steals the pick.
            for (pkg in DOCUMENTS_UI_CANDIDATES) {
                try {
                    context.packageManager.getPackageInfo(pkg, 0)
                    setPackage(pkg)
                    Log.i(TAG, "pin DocumentsUI package=$pkg")
                    break
                } catch (_: PackageManager.NameNotFoundException) {
                    // try next
                }
            }
        }
    }

    // ---- discovery ----

    private fun findBackupDocumentUri(
        resolver: android.content.ContentResolver,
        authority: String,
    ): Uri? {
        val rootDocId = myDriveDocumentId(resolver, authority) ?: return null
        val keepsakeId = findChildDocumentId(resolver, authority, rootDocId, "Keepsake")
            ?: return null
        val backupId = findChildDocumentId(resolver, authority, keepsakeId, "backup")
            ?: return null
        return DocumentsContract.buildDocumentUri(authority, backupId)
    }

    private fun findMyDriveRootDocumentUri(
        resolver: android.content.ContentResolver,
        authority: String,
    ): Uri? {
        val id = myDriveDocumentId(resolver, authority) ?: return null
        return DocumentsContract.buildDocumentUri(authority, id)
    }

    private fun myDriveDocumentId(
        resolver: android.content.ContentResolver,
        authority: String,
    ): String? {
        val rootsUri = DocumentsContract.buildRootsUri(authority)
        resolver.query(rootsUri, null, null, null, null)?.use { c ->
            val idCol = c.getColumnIndex(DocumentsContract.Root.COLUMN_DOCUMENT_ID)
            val titleCol = c.getColumnIndex(DocumentsContract.Root.COLUMN_TITLE)
            val flagsCol = c.getColumnIndex(DocumentsContract.Root.COLUMN_FLAGS)
            val summaryCol = c.getColumnIndex(DocumentsContract.Root.COLUMN_SUMMARY)
            while (c.moveToNext()) {
                val docId = c.str(idCol) ?: continue
                val title = c.str(titleCol).orEmpty()
                val summary = c.str(summaryCol).orEmpty()
                val flags = if (flagsCol >= 0) c.getInt(flagsCol) else 0
                Log.i(TAG, "root auth=$authority id=$docId title=$title summary=$summary flags=$flags")
                // Prefer primary "My Drive" / "我的云端硬盘" style roots
                val looksLikeMyDrive =
                    title.contains("My Drive", ignoreCase = true) ||
                        title.contains("云端硬盘") ||
                        title.contains("Drive", ignoreCase = true) ||
                        summary.contains("@") // often the account email
                val supportsCreate =
                    flags and DocumentsContract.Root.FLAG_SUPPORTS_CREATE != 0
                if (looksLikeMyDrive || supportsCreate) {
                    return docId
                }
            }
            // Any root is better than nothing
            if (c.moveToFirst()) {
                return c.str(idCol)
            }
        }
        return null
    }

    private fun findChildDocumentId(
        resolver: android.content.ContentResolver,
        authority: String,
        parentDocumentId: String,
        displayName: String,
    ): String? {
        val children = DocumentsContract.buildChildDocumentsUri(authority, parentDocumentId)
        return resolver.query(
            children,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            ),
            null,
            null,
            null,
        )?.use { c ->
            val idCol = 0
            val nameCol = 1
            val mimeCol = 2
            while (c.moveToNext()) {
                val name = c.getString(nameCol) ?: continue
                val mime = c.getString(mimeCol)
                Log.d(TAG, "child of $parentDocumentId: $name mime=$mime")
                if (name.equals(displayName, ignoreCase = true)) {
                    return@use c.getString(idCol)
                }
            }
            null
        }
    }

    private fun staticRootCandidates(): List<Uri> {
        val auth = DRIVE_AUTHORITY
        return listOf(
            DocumentsContract.buildDocumentUri(auth, "root"),
            Uri.parse("content://$auth/document/root"),
            DocumentsContract.buildRootUri(auth, "root"),
            DocumentsContract.buildDocumentUri(auth, "acc=1;doc=root"),
            Uri.parse("content://$auth/document/" + Uri.encode("acc=1;doc=root")),
            DocumentsContract.buildDocumentUri(DRIVE_AUTHORITY_LEGACY, "root"),
        )
    }

    private fun Cursor.str(col: Int): String? =
        if (col >= 0 && !isNull(col)) getString(col) else null
}
