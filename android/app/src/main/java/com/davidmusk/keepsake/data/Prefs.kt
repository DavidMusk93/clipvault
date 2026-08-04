package com.davidmusk.keepsake.data

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri

class Prefs(context: Context) {
    private val sp: SharedPreferences =
        context.getSharedPreferences("keepsake", Context.MODE_PRIVATE)

    var backupTreeUri: Uri?
        get() = sp.getString(KEY_TREE, null)?.let(Uri::parse)
        set(value) {
            sp.edit().putString(KEY_TREE, value?.toString()).apply()
        }

    var lastSyncedSha: String?
        get() = sp.getString(KEY_SHA, null)
        set(value) {
            sp.edit().putString(KEY_SHA, value).apply()
        }

    var lastAutoSyncAtMs: Long
        get() = sp.getLong(KEY_AUTO_SYNC_AT, 0L)
        set(value) {
            sp.edit().putLong(KEY_AUTO_SYNC_AT, value).apply()
        }

    var lastAutoSyncMessage: String?
        get() = sp.getString(KEY_AUTO_SYNC_MSG, null)
        set(value) {
            sp.edit().putString(KEY_AUTO_SYNC_MSG, value).apply()
        }

    companion object {
        private const val KEY_TREE = "backup_tree_uri"
        private const val KEY_SHA = "last_synced_sha"
        private const val KEY_AUTO_SYNC_AT = "last_auto_sync_at"
        private const val KEY_AUTO_SYNC_MSG = "last_auto_sync_msg"
    }
}
