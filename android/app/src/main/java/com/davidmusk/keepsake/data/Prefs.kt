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

    companion object {
        private const val KEY_TREE = "backup_tree_uri"
        private const val KEY_SHA = "last_synced_sha"
    }
}
