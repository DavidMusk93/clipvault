package com.davidmusk.keepsake

import android.app.Application
import com.davidmusk.keepsake.data.BackupRepository
import com.davidmusk.keepsake.data.BackupSyncWorker
import com.davidmusk.keepsake.data.CaptureQueueStore
import com.davidmusk.keepsake.data.Prefs

class KeepsakeApp : Application() {
    lateinit var prefs: Prefs
        private set
    lateinit var backupRepo: BackupRepository
        private set
    lateinit var captures: CaptureQueueStore
        private set

    override fun onCreate() {
        super.onCreate()
        prefs = Prefs(this)
        backupRepo = BackupRepository(this, prefs)
        captures = CaptureQueueStore(this)
        // Mature auto-refresh: poll Drive fingerprint in background when backup tree is linked.
        if (backupRepo.hasBackupRoot()) {
            BackupSyncWorker.ensureScheduled(this)
        }
    }
}

val Application.keepsake: KeepsakeApp
    get() = this as KeepsakeApp
