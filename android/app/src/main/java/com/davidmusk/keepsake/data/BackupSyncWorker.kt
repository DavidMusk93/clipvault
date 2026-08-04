package com.davidmusk.keepsake.data

import android.content.Context
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.davidmusk.keepsake.KeepsakeApp
import java.util.concurrent.TimeUnit

/**
 * Background poll of Google Drive backup fingerprint.
 *
 * Drive SAF does not provide reliable push/change notifications for third-party apps.
 * Industry pattern for folder-backed cloud readers:
 *   - peek remote hash (STATUS/MANIFEST)
 *   - full pull only when hash differs
 *   - WorkManager periodic + app-resume trigger
 */
class BackupSyncWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        return try {
            val app = applicationContext as? KeepsakeApp
                ?: return Result.success()
            if (!app.backupRepo.hasBackupRoot()) return Result.success()
            val r = app.backupRepo.syncIfChanged(force = false)
            Log.i(TAG, "auto-sync: ${r.message}")
            Result.success()
        } catch (e: Exception) {
            Log.e(TAG, "auto-sync failed", e)
            Result.retry()
        }
    }

    companion object {
        private const val TAG = "BackupSyncWorker"
        const val UNIQUE_NAME = "keepsake_backup_sync"

        /** 15 min is WorkManager minimum for PeriodicWorkRequest. */
        fun ensureScheduled(context: Context) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()
            val req = PeriodicWorkRequestBuilder<BackupSyncWorker>(15, TimeUnit.MINUTES)
                .setConstraints(constraints)
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                UNIQUE_NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                req,
            )
            Log.i(TAG, "scheduled unique periodic work")
        }

        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(UNIQUE_NAME)
        }
    }
}
