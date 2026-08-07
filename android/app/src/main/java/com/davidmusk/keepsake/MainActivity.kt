package com.davidmusk.keepsake

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContract
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.staggeredgrid.LazyVerticalStaggeredGrid
import androidx.compose.foundation.lazy.staggeredgrid.StaggeredGridCells
import androidx.compose.foundation.lazy.staggeredgrid.items
import androidx.compose.foundation.lazy.staggeredgrid.rememberLazyStaggeredGridState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.OpenInBrowser
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Share
import com.davidmusk.keepsake.data.OperationLog
import com.davidmusk.keepsake.data.ClipEvent
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.AssistChip
import androidx.compose.material.icons.filled.RestoreFromTrash
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Delete
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.davidmusk.keepsake.R
import com.davidmusk.keepsake.data.BackupRepository
import com.davidmusk.keepsake.data.BackupSyncWorker
import com.davidmusk.keepsake.data.ClipboardRow
import com.davidmusk.keepsake.data.CapturedClip
import com.davidmusk.keepsake.data.ClipboardReader
import com.davidmusk.keepsake.data.DriveTreePicker
import com.davidmusk.keepsake.data.LocalCapture
import com.davidmusk.keepsake.ui.DetailContent
import com.davidmusk.keepsake.ui.ListItemBody
import com.davidmusk.keepsake.ui.TypeBadge
import com.davidmusk.keepsake.ui.theme.KeepsakeTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale


class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application.keepsake
        setContent {
            KeepsakeTheme {
                KeepsakeRoot(
                    app = app,
                    onCopyText = { text ->
                        val cm = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
                        cm.setPrimaryClip(ClipData.newPlainText("keepsake", text))
                        Toast.makeText(this, "已复制", Toast.LENGTH_SHORT).show()
                    },
                    onPasteFromClipboard = {
                        val cap = ClipboardReader.read(this)
                        if (cap == null) {
                            Toast.makeText(this, "剪贴板为空，请先复制内容再粘贴", Toast.LENGTH_SHORT).show()
                            null
                        } else cap
                    },
                )
            }
        }
    }
}

private enum class Tab { Backup, Captures, Ops }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun KeepsakeRoot(
    app: KeepsakeApp,
    onCopyText: (String) -> Unit,
    onPasteFromClipboard: () -> CapturedClip?,
) {
    val scope = rememberCoroutineScope()
    val ctx = LocalContext.current
    var tab by remember { mutableStateOf(Tab.Backup) }
    var items by remember { mutableStateOf<List<ClipboardRow>>(emptyList()) }
    var captures by remember { mutableStateOf<List<LocalCapture>>(emptyList()) }
    var query by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(false) }
    var statusMsg by remember { mutableStateOf<String?>(null) }
    var selected by remember { mutableStateOf<ClipboardRow?>(null) }
    var hasRoot by remember { mutableStateOf(app.backupRepo.hasBackupRoot()) }
    var offset by remember { mutableIntStateOf(0) }
    var endReached by remember { mutableStateOf(false) }
    var trashOnly by remember { mutableStateOf(false) }
    var opLogs by remember { mutableStateOf<List<OperationLog>>(emptyList()) }

    // Fully custom contract — subclassing OpenDocumentTree still got MIUI intent-hijack.
    val openTree = rememberLauncherForActivityResult(
        object : ActivityResultContract<Uri?, Uri?>() {
            override fun createIntent(context: android.content.Context, input: Uri?): Intent {
                return DriveTreePicker.openTreeIntent(context, initial = input)
            }

            override fun parseResult(resultCode: Int, intent: Intent?): Uri? {
                return if (resultCode == Activity.RESULT_OK) intent?.data else null
            }
        }
    ) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            loading = true
            app.backupRepo.persistTreeUri(uri)
            hasRoot = true
            BackupSyncWorker.ensureScheduled(ctx.applicationContext)
            val r = app.backupRepo.syncFromBackup()
            statusMsg = r.message
            offset = 0
            endReached = false
            items = app.backupRepo.queryItems(limit = 80, offset = 0, q = query.ifBlank { null })
            loading = false
        }
    }

    fun launchDriveFolderPicker() {
        // Always open DocumentsUI. Do NOT hard-fail on package visibility checks
        // (Android 11+ returns "not installed" without <queries> — already fixed in manifest).
        val driveOk = DriveTreePicker.isDriveInstalled(ctx.applicationContext)
        if (!driveOk) {
            // Soft warning only — still try the picker (roots may still list Drive).
            Toast.makeText(
                ctx,
                "若列表里没有 Drive，请先安装并登录 Google 云端硬盘",
                Toast.LENGTH_SHORT,
            ).show()
        }
        scope.launch {
            loading = true
            statusMsg = "打开文件页 → 左上角显示根目录 → Drive → Keepsake → backup"
            val initial = withContext(Dispatchers.IO) {
                DriveTreePicker.bestInitialUri(ctx.applicationContext)
            }
            loading = false
            openTree.launch(initial)
        }
    }

    suspend fun refreshList(reset: Boolean) {
        if (reset) {
            offset = 0
            endReached = false
        }
        val page = app.backupRepo.queryItems(
            limit = 80,
            offset = if (reset) 0 else offset,
            q = query.ifBlank { null },
            trashOnly = trashOnly,
        )
        items = if (reset) page else items + page
        offset = items.size
        if (page.size < 80) endReached = true
    }

    suspend fun refreshOpLogs() {
        opLogs = app.backupRepo.queryOperationLogs(limit = 300)
    }

    suspend fun syncAndLoad(force: Boolean = false, quiet: Boolean = false) {
        if (!quiet) loading = true
        if (app.backupRepo.hasBackupRoot()) {
            BackupSyncWorker.ensureScheduled(ctx.applicationContext)
            val r = if (force) {
                app.backupRepo.syncFromBackup()
            } else {
                app.backupRepo.syncIfChanged(force = false)
            }
            statusMsg = formatSyncStatus(r.message, app.prefs.lastAutoSyncAtMs)
            refreshList(reset = true)
        }
        captures = app.captures.list()
        if (!quiet) loading = false
    }

    // First open + every resume: cheap fingerprint check, pull only when Drive changed.
    LaunchedEffect(Unit) {
        syncAndLoad(force = false)
    }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, hasRoot) {
        val obs = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME && hasRoot) {
                scope.launch {
                    syncAndLoad(force = false, quiet = true)
                }
            }
        }
        lifecycleOwner.lifecycle.addObserver(obs)
        onDispose { lifecycleOwner.lifecycle.removeObserver(obs) }
    }

    // Detail as overlay: keep list/tab/scroll composition alive so back returns to
    // the same place (not a recreated "首页" at scroll 0). Early-return used to dispose
    // LazyStaggeredGridState and forced users to the top every time.
    val gridState = rememberLazyStaggeredGridState()

    BackHandler(enabled = selected != null) {
        selected = null
    }

    Box(Modifier.fillMaxSize()) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Image(
                                painter = painterResource(R.drawable.keepsake_logo),
                                contentDescription = "Keepsake",
                                modifier = Modifier
                                    .size(34.dp)
                                    .clip(CircleShape)
                                    .border(
                                        1.dp,
                                        MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.45f),
                                        CircleShape,
                                    ),
                                contentScale = ContentScale.Crop,
                            )
                            Spacer(Modifier.width(10.dp))
                            Column {
                                Text("Keepsake", fontWeight = FontWeight.SemiBold)
                                Text(
                                    "你的剪贴板记忆",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                                )
                            }
                        }
                    },
                    actions = {
                        IconButton(onClick = {
                            scope.launch {
                                val cap = onPasteFromClipboard() ?: return@launch
                                app.captures.insertCapture(cap, source = "paste")
                                captures = app.captures.list()
                                tab = Tab.Captures
                                val kind = when (cap.type) {
                                    "html" -> "富文本"
                                    "url" -> "链接"
                                    else -> "文本"
                                }
                                Toast.makeText(ctx, "已记下$kind", Toast.LENGTH_SHORT).show()
                            }
                        }) {
                            Icon(Icons.Default.ContentPaste, contentDescription = "粘贴并记下")
                        }
                        IconButton(onClick = { launchDriveFolderPicker() }) {
                            Icon(Icons.Default.FolderOpen, contentDescription = "选择云端文件夹")
                        }
                        IconButton(onClick = {
                            scope.launch { syncAndLoad(force = true, quiet = false) }
                        }) {
                            Icon(Icons.Default.Refresh, contentDescription = "刷新")
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = MaterialTheme.colorScheme.background,
                    ),
                )
            },
        ) { padding ->
            Column(
                Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .padding(horizontal = 16.dp),
            ) {
                if (!hasRoot) {
                    SetupCard(onPick = { launchDriveFolderPicker() })
                    Spacer(Modifier.height(12.dp))
                }

                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(
                        selected = tab == Tab.Backup,
                        onClick = {
                            tab = Tab.Backup
                            // Returning to history keeps prior trashOnly; re-show main library by default.
                            if (trashOnly) {
                                trashOnly = false
                                scope.launch {
                                    loading = true
                                    refreshList(true)
                                    loading = false
                                }
                            }
                        },
                        label = { Text("历史") },
                    )
                    FilterChip(
                        selected = tab == Tab.Captures,
                        onClick = {
                            tab = Tab.Captures
                            scope.launch { captures = app.captures.list() }
                        },
                        label = { Text("随手记") },
                    )
                    FilterChip(
                        selected = tab == Tab.Ops,
                        onClick = {
                            tab = Tab.Ops
                            scope.launch { refreshOpLogs() }
                        },
                        label = { Text("操作") },
                        leadingIcon = if (tab == Tab.Ops) {
                            { Icon(Icons.Default.History, null, Modifier.size(16.dp)) }
                        } else null,
                    )
                }

                Spacer(Modifier.height(8.dp))

                if (tab == Tab.Backup) {
                    OutlinedTextField(
                        value = query,
                        onValueChange = { query = it },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                        leadingIcon = { Icon(Icons.Default.Search, null) },
                        placeholder = { Text("搜索文本 / OCR / 来源…") },
                        trailingIcon = {
                            Text(
                                "搜索",
                                modifier = Modifier
                                    .padding(end = 12.dp)
                                    .clickable {
                                        scope.launch {
                                            loading = true
                                            refreshList(true)
                                            loading = false
                                        }
                                    },
                                color = MaterialTheme.colorScheme.primary,
                                fontWeight = FontWeight.Medium,
                            )
                        },
                    )
                    Spacer(Modifier.height(8.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilterChip(
                            selected = !trashOnly,
                            onClick = {
                                if (trashOnly) {
                                    trashOnly = false
                                    scope.launch {
                                        loading = true
                                        refreshList(true)
                                        loading = false
                                    }
                                }
                            },
                            label = { Text("主库") },
                        )
                        FilterChip(
                            selected = trashOnly,
                            onClick = {
                                if (!trashOnly) {
                                    trashOnly = true
                                    scope.launch {
                                        loading = true
                                        refreshList(true)
                                        loading = false
                                    }
                                }
                            },
                            label = { Text("回收箱") },
                            leadingIcon = {
                                Icon(Icons.Default.Delete, null, Modifier.size(16.dp))
                            },
                        )
                    }
                    statusMsg?.let {
                        Text(
                            it,
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.55f),
                            modifier = Modifier.padding(vertical = 6.dp),
                        )
                    }
                    if (trashOnly) {
                        Text(
                            "只读展示云端备份中的回收箱（TTL 30 天）。恢复/删除请在 Mac Web 操作。",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
                            modifier = Modifier.padding(bottom = 4.dp),
                        )
                    }
                } else if (tab == Tab.Captures) {
                    Text(
                        "顶栏粘贴，或从其他 App 分享到这里。先保存在本机。",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.55f),
                        modifier = Modifier.padding(vertical = 6.dp),
                    )
                } else {
                    Text(
                        "操作日志来自 Mac 备份库；来源着色；正文不换行，可上下左右滑动。",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.55f),
                        modifier = Modifier.padding(vertical = 6.dp),
                    )
                }

                if (loading && items.isEmpty() && captures.isEmpty() && opLogs.isEmpty()) {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator()
                    }
                } else if (tab == Tab.Ops) {
                    if (opLogs.isEmpty()) {
                        Text(
                            "暂无操作日志。请先同步最新 Mac 备份（含 operation_logs 表）。",
                            modifier = Modifier.padding(24.dp),
                        )
                    } else {
                        LazyColumn(
                            contentPadding = PaddingValues(bottom = 24.dp),
                            verticalArrangement = Arrangement.spacedBy(10.dp),
                            modifier = Modifier.fillMaxSize(),
                        ) {
                            items(opLogs, key = { it.id }) { log ->
                                OpLogCard(log)
                            }
                        }
                    }
                } else if (tab == Tab.Backup) {
                    // Mature masonry: official LazyVerticalStaggeredGrid (Compose foundation).
                    // gridState is hoisted above so detail overlay does not reset scroll.
                    LaunchedEffect(gridState, endReached, loading) {
                        snapshotFlow {
                            val info = gridState.layoutInfo
                            val last = info.visibleItemsInfo.lastOrNull()?.index ?: 0
                            last >= info.totalItemsCount - 4
                        }.distinctUntilChanged().collect { nearEnd ->
                            if (nearEnd && !endReached && !loading && hasRoot) {
                                loading = true
                                refreshList(reset = false)
                                loading = false
                            }
                        }
                    }
                    if (items.isEmpty() && hasRoot) {
                        Text(
                            "这里还没有条目。回到前台或联网后会自动同步；也可点右上角强制刷新。",
                            modifier = Modifier.padding(24.dp),
                        )
                    } else {
                        LazyVerticalStaggeredGrid(
                            columns = StaggeredGridCells.Adaptive(minSize = 160.dp),
                            state = gridState,
                            contentPadding = PaddingValues(bottom = 24.dp, top = 4.dp),
                            verticalItemSpacing = 10.dp,
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                            modifier = Modifier.fillMaxSize(),
                        ) {
                            items(items, key = { it.id }) { row ->
                                ItemCard(
                                    row = row,
                                    repo = app.backupRepo,
                                    onClick = { selected = row },
                                )
                            }
                        }
                    }
                } else {
                    LazyColumn(
                        contentPadding = PaddingValues(bottom = 24.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier.fillMaxSize(),
                    ) {
                        items(captures, key = { it.id }) { cap ->
                            CaptureCard(cap = cap, onCopy = {
                                cap.text?.let(onCopyText)
                            })
                        }
                        if (captures.isEmpty()) {
                            item {
                                Text(
                                    "还没有随手记。点顶栏粘贴，或从其他 App 分享到 Keepsake。",
                                    modifier = Modifier.padding(24.dp),
                                )
                            }
                        }
                    }
                }
            }
        }

        // Full-screen detail over the still-alive home surface.
        selected?.let { row ->
            DetailScreen(
                row = row,
                repo = app.backupRepo,
                onBack = { selected = null },
                // Stay on detail after copy — leave via back / system back.
                onCopy = { text -> onCopyText(text) },
            )
        }
    }

}

@Composable
private fun SetupCard(onPick: () -> Unit) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        shape = RoundedCornerShape(16.dp),
        elevation = CardDefaults.cardElevation(2.dp),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("打开云端记忆", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(
                "电脑端 Keepsake 会把记忆同步到 Google 云端硬盘。点下方按钮将直接打开云端硬盘（需已安装并登录同一账号）。进入 Keepsake → backup 后点「使用此文件夹」。",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.75f),
            )
            Button(onClick = onPick) {
                Icon(Icons.Default.FolderOpen, null, Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("从 Google 云端硬盘选择")
            }
        }
    }
}

@Composable
private fun ItemCard(
    row: ClipboardRow,
    repo: BackupRepository,
    onClick: () -> Unit,
) {
    val surface = if (row.inTrash) {
        MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)
    } else {
        MaterialTheme.colorScheme.surface
    }
    Card(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(containerColor = surface),
        elevation = CardDefaults.cardElevation(1.dp),
        border = if (row.inTrash) {
            androidx.compose.foundation.BorderStroke(
                1.dp,
                MaterialTheme.colorScheme.outline.copy(alpha = 0.35f),
            )
        } else null,
    ) {
        Column(Modifier.padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TypeBadge(row.type)
                if (row.copyCount > 1) {
                    Spacer(Modifier.width(6.dp))
                    Text(
                        "×${row.copyCount}",
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
                if (row.inTrash) {
                    Spacer(Modifier.width(6.dp))
                    Icon(
                        Icons.Default.Delete,
                        contentDescription = "回收箱",
                        modifier = Modifier.size(14.dp),
                        tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f),
                    )
                }
                Spacer(Modifier.weight(1f))
                Text(
                    row.displayTime,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f),
                    maxLines = 1,
                )
            }
            if (row.inTrash) {
                Spacer(Modifier.height(2.dp))
                Text(
                    "删除 ${row.displayDeletedAt ?: "—"} · 30 天后清除",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.4f),
                    maxLines = 2,
                )
            }
            row.sourceApp?.let {
                Spacer(Modifier.height(4.dp))
                Text(
                    it,
                    style = MaterialTheme.typography.labelSmall,
                    maxLines = 1,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.4f),
                )
            }
            Spacer(Modifier.height(8.dp))
            ListItemBody(row = row, repo = repo)
        }
    }
}

/** Align with web ops drawer: source rail + pill colors. */
private data class OpsSourceStyle(
    val key: String,
    val rail: Color,
    val ink: Color,
    val soft: Color,
)

private fun opsSourceStyle(source: String): OpsSourceStyle {
    val s = source.lowercase().trim()
    val key = when {
        s == "web" || s.contains("web") || s.contains("ui") -> "web"
        s == "clipboard" || s.contains("clip") -> "clipboard"
        s == "backup" || s.contains("back") -> "backup"
        s == "maintenance" || s.contains("maint") || s.contains("purge") || s.contains("cron") -> "maintenance"
        s == "app" || s.contains("app") -> "app"
        s == "sync" || s.contains("sync") -> "sync"
        else -> "system"
    }
    return when (key) {
        // Match web/index.html .ops-item.src-*
        "web" -> OpsSourceStyle(key, Color(0xFF007AFF), Color(0xFF0056B3), Color(0x24007AFF))
        "clipboard" -> OpsSourceStyle(key, Color(0xFF34C759), Color(0xFF1B7A34), Color(0x2934C759))
        "backup" -> OpsSourceStyle(key, Color(0xFFAF52DE), Color(0xFF7A2FA8), Color(0x24AF52DE))
        "maintenance" -> OpsSourceStyle(key, Color(0xFFFF9500), Color(0xFFB56A00), Color(0x29FF9500))
        "app" -> OpsSourceStyle(key, Color(0xFF5856D6), Color(0xFF3B3A9A), Color(0x245856D6))
        "sync" -> OpsSourceStyle(key, Color(0xFF32ADE6), Color(0xFF1A6F99), Color(0x2932ADE6))
        else -> OpsSourceStyle("system", Color(0xFF8E8E93), Color(0xFF3A3A3C), Color(0x298E8E93))
    }
}

@Composable
private fun OpLogCard(log: OperationLog) {
    val style = opsSourceStyle(log.source)
    val hScroll = rememberScrollState()
    val vScroll = rememberScrollState()
    val fields = buildList {
        add("时间" to log.displayTime)
        add("动作" to log.action)
        add("来源" to log.source)
        log.itemId?.takeIf { it.isNotBlank() }?.let { add("条目 ID" to it) }
        log.contentHash?.takeIf { it.isNotBlank() }?.let { add("contentHash" to it) }
        add("日志 ID" to log.id)
        log.detail?.takeIf { it.isNotBlank() }?.let { add("详情" to it) }
    }

    Card(
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        elevation = CardDefaults.cardElevation(1.dp),
        border = BorderStroke(0.5.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.28f)),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .height(IntrinsicSize.Min),
        ) {
            // Left color rail (web .ops-item border-left)
            Box(
                Modifier
                    .width(3.dp)
                    .fillMaxHeight()
                    .background(style.rail),
            )
            Column(Modifier.weight(1f)) {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(start = 12.dp, end = 12.dp, top = 10.dp, bottom = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        log.action,
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    Surface(
                        shape = RoundedCornerShape(999.dp),
                        color = style.soft,
                    ) {
                        Text(
                            log.source.ifBlank { "system" },
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                            style = MaterialTheme.typography.labelSmall,
                            fontWeight = FontWeight.SemiBold,
                            color = style.ink,
                            maxLines = 1,
                        )
                    }
                    Text(
                        log.displayTime,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
                        maxLines = 1,
                    )
                }
                // XY pan, no soft wrap — mirror web .ops-scroll + white-space:pre
                Box(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(max = 160.dp)
                        .padding(start = 12.dp, end = 4.dp, bottom = 10.dp)
                        .horizontalScroll(hScroll)
                        .verticalScroll(vScroll),
                ) {
                    Column(
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                        modifier = Modifier.padding(end = 8.dp),
                    ) {
                        fields.forEach { (label, value) ->
                            OpFieldRow(
                                label = label,
                                value = value,
                                mono = label in setOf("条目 ID", "contentHash", "日志 ID"),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun OpFieldRow(label: String, value: String, mono: Boolean) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Text(
            label,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f),
            fontWeight = FontWeight.Medium,
            softWrap = false,
            maxLines = 1,
            modifier = Modifier.width(72.dp),
        )
        Text(
            value,
            style = MaterialTheme.typography.bodySmall,
            fontFamily = if (mono) FontFamily.Monospace else FontFamily.Default,
            // Hard newlines OK; no soft wrap — pan horizontally for long IDs/hashes
            softWrap = false,
            overflow = TextOverflow.Visible,
        )
    }
}

private fun formatSyncStatus(message: String, atMs: Long): String {
    if (atMs <= 0L) return message
    val t = SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(atMs))
    return "$message · 自动 $t"
}

@Composable
private fun CaptureCard(cap: LocalCapture, onCopy: () -> Unit) {
    Card(
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(
                    "${cap.type.uppercase()} · ${cap.source} · ${cap.displayTime}",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
                )
                Spacer(Modifier.height(4.dp))
                Text(cap.preview, style = MaterialTheme.typography.bodyMedium, maxLines = 4)
            }
            IconButton(onClick = onCopy) {
                Icon(Icons.Default.ContentCopy, contentDescription = "复制")
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DetailScreen(
    row: ClipboardRow,
    repo: BackupRepository,
    onBack: () -> Unit,
    onCopy: (String) -> Unit,
) {
    val ctx = LocalContext.current
    val textBody = row.textContent ?: row.url ?: row.ocrText
        ?: row.htmlContent?.let { com.davidmusk.keepsake.ui.stripHtml(it) }
    val openUrl = row.url ?: row.textContent?.takeIf {
        it.startsWith("http://") || it.startsWith("https://")
    }

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        TypeBadge(row.type)
                        Spacer(Modifier.width(8.dp))
                        Text(
                            row.sourceApp ?: "详情",
                            maxLines = 1,
                            style = MaterialTheme.typography.titleMedium,
                        )
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                },
                actions = {
                    if (!textBody.isNullOrBlank()) {
                        IconButton(onClick = { onCopy(textBody) }) {
                            Icon(Icons.Default.ContentCopy, contentDescription = "复制")
                        }
                    }
                    if (!textBody.isNullOrBlank()) {
                        IconButton(onClick = {
                            val send = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_TEXT, textBody)
                            }
                            ctx.startActivity(Intent.createChooser(send, "分享"))
                        }) {
                            Icon(Icons.Default.Share, contentDescription = "分享")
                        }
                    }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            Text(
                "${row.displayTime} · ${row.sourceApp ?: "未知来源"}",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.55f),
            )
            if (row.copyCount > 1) {
                Spacer(Modifier.height(4.dp))
                Text(
                    "复制频次 ×${row.copyCount}",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.primary,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            if (row.inTrash) {
                Spacer(Modifier.height(2.dp))
                Text(
                    "回收箱 · 删除于 ${row.displayDeletedAt ?: "—"}",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
                )
            }
            Spacer(Modifier.height(12.dp))
            Box(Modifier.weight(1f, fill = true).fillMaxWidth()) {
                Column(Modifier.fillMaxSize()) {
                    Box(Modifier.weight(1f, fill = true).fillMaxWidth()) {
                        DetailContent(row = row, repo = repo, modifier = Modifier.fillMaxSize())
                    }
                    // Lightweight: single-ref items skip event timeline chrome (design-taste).
                    if (row.copyCount > 1) {
                        Spacer(Modifier.height(10.dp))
                        ItemEventsSection(itemId = row.id, repo = repo, expectedCount = row.copyCount)
                    }
                }
            }
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (!textBody.isNullOrBlank()) {
                    Button(
                        onClick = { onCopy(textBody) },
                        modifier = Modifier.weight(1f),
                    ) {
                        Icon(Icons.Default.ContentCopy, null, Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("复制")
                    }
                }
                if (!openUrl.isNullOrBlank()) {
                    OutlinedButton(
                        onClick = {
                            try {
                                ctx.startActivity(
                                    Intent(Intent.ACTION_VIEW, Uri.parse(openUrl))
                                )
                            } catch (_: Exception) {
                                Toast.makeText(ctx, "无法打开链接", Toast.LENGTH_SHORT).show()
                            }
                        },
                        modifier = Modifier.weight(1f),
                    ) {
                        Icon(Icons.Default.OpenInBrowser, null, Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("打开")
                    }
                }
            }
        }
    }
}


@Composable
private fun ItemEventsSection(
    itemId: String,
    repo: BackupRepository,
    expectedCount: Int = 2,
) {
    var events by remember(itemId) { mutableStateOf<List<ClipEvent>>(emptyList()) }
    var loaded by remember(itemId) { mutableStateOf(false) }
    var expanded by remember(itemId) { mutableStateOf(false) }
    // Lazy: fetch only when user expands (not on detail open).
    LaunchedEffect(itemId, expanded) {
        if (expanded && !loaded) {
            events = repo.queryItemEvents(itemId, limit = 100)
            loaded = true
        }
    }
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f), RoundedCornerShape(12.dp))
            .padding(12.dp),
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .clickable { expanded = !expanded },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Default.History, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.width(6.dp))
            Text(
                if (expanded) "事件时间线 · $expectedCount 次" else "事件时间线 · $expectedCount 次",
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            Text(
                if (expanded && loaded) "${events.size}" else "…",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f),
            )
        }
        if (expanded) {
            Spacer(Modifier.height(8.dp))
            if (!loaded) {
                Text("加载中…", style = MaterialTheme.typography.bodySmall)
            } else if (events.isEmpty()) {
                Text("暂无事件（需 Mac 备份含 clipboard_events）", style = MaterialTheme.typography.bodySmall)
            } else {
                events.forEach { ev ->
                    Column(Modifier.padding(vertical = 4.dp)) {
                        Text(ev.displayTime, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
                        Text(
                            buildString {
                                append(ev.kind)
                                if (ev.type.isNotBlank()) append(" · ").append(ev.type)
                                if (!ev.sourceApp.isNullOrBlank()) append(" · ").append(ev.sourceApp)
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.65f),
                        )
                    }
                }
            }
        }
    }
}
