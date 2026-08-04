package com.davidmusk.keepsake.data

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.util.Log

/**
 * Helpers so OPEN_DOCUMENT_TREE lands on Google Drive (not only local storage).
 * MIUI DocumentsUI often hides roots until the drawer is opened; EXTRA_INITIAL_URI
 * is the reliable way to start inside Drive's document provider.
 */
object DriveTreePicker {
    const val DRIVE_AUTHORITY = "com.google.android.apps.docs.storage"
    private const val TAG = "DriveTreePicker"

    fun isDriveInstalled(context: Context): Boolean {
        return try {
            context.packageManager.getPackageInfo("com.google.android.apps.docs", 0)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
    }

    /**
     * Candidate document URIs that OEMs accept as EXTRA_INITIAL_URI for Drive.
     * First match that DocumentsUI can resolve wins.
     */
    fun initialUris(): List<Uri> {
        val auth = DRIVE_AUTHORITY
        return listOf(
            // Most common on modern Drive
            DocumentsContract.buildDocumentUri(auth, "root"),
            DocumentsContract.buildRootUri(auth, "root"),
            DocumentsContract.buildRootUri(auth, "home"),
            Uri.parse("content://$auth/document/root"),
            Uri.parse("content://$auth/root/root"),
            // Account-scoped root (acc index varies; 1 is usual primary account)
            Uri.parse("content://$auth/document/" + Uri.encode("acc=1;doc=root")),
            DocumentsContract.buildDocumentUri(auth, "acc=1;doc=root"),
        )
    }

    fun bestInitialUri(context: Context): Uri? {
        if (!isDriveInstalled(context)) return null
        // Prefer document URI form; DocumentsUI resolves Drive root without needing a prior grant.
        return initialUris().firstOrNull().also {
            Log.i(TAG, "initialUri=$it")
        }
    }

    /**
     * Full intent for tree pick, with Drive initial location when possible.
     * Callers that use ActivityResultContracts.OpenDocumentTree can pass [bestInitialUri].
     */
    fun openTreeIntent(context: Context): Intent {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                bestInitialUri(context)?.let { uri ->
                    putExtra(DocumentsContract.EXTRA_INITIAL_URI, uri)
                }
            }
        }
        return intent
    }
}
