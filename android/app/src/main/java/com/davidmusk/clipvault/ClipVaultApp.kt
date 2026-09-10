package com.davidmusk.clipvault

import android.app.Application
import com.davidmusk.clipvault.data.BackupRepository
import com.davidmusk.clipvault.data.BackupSyncWorker
import com.davidmusk.clipvault.data.CaptureQueueStore
import com.davidmusk.clipvault.data.Prefs

class ClipVaultApp : Application() {
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

val Application.clipvault: ClipVaultApp
    get() = this as ClipVaultApp
