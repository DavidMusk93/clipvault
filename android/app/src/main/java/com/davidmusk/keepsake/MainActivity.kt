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
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContract
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
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
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.davidmusk.keepsake.R
import com.davidmusk.keepsake.data.BackupRepository
import com.davidmusk.keepsake.data.ClipboardRow
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
                        val cm = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
                        val text = cm.primaryClip?.getItemAt(0)?.coerceToText(this)?.toString()
                        if (text.isNullOrBlank()) {
                            Toast.makeText(this, "剪贴板为空，请先复制内容再粘贴", Toast.LENGTH_SHORT).show()
                            null
                        } else text
                    },
                )
            }
        }
    }
}

private enum class Tab { Backup, Captures }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun KeepsakeRoot(
    app: KeepsakeApp,
    onCopyText: (String) -> Unit,
    onPasteFromClipboard: () -> String?,
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
        )
        items = if (reset) page else items + page
        offset = items.size
        if (page.size < 80) endReached = true
    }

    suspend fun syncAndLoad() {
        loading = true
        if (app.backupRepo.hasBackupRoot()) {
            val r = app.backupRepo.syncFromBackup()
            statusMsg = r.message
            refreshList(reset = true)
        }
        captures = app.captures.list()
        loading = false
    }

    LaunchedEffect(Unit) {
        syncAndLoad()
    }

    if (selected != null) {
        DetailScreen(
            row = selected!!,
            repo = app.backupRepo,
            onBack = { selected = null },
            onCopy = { text -> onCopyText(text); selected = null },
        )
        return
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Image(
                            painter = painterResource(R.drawable.keepsake_logo),
                            contentDescription = null,
                            modifier = Modifier
                                .size(36.dp)
                                .clip(CircleShape),
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
                            val text = onPasteFromClipboard() ?: return@launch
                            app.captures.insertText(text, source = "paste")
                            captures = app.captures.list()
                            tab = Tab.Captures
                            Toast.makeText(ctx, "已记下", Toast.LENGTH_SHORT).show()
                        }
                    }) {
                        Icon(Icons.Default.ContentPaste, contentDescription = "粘贴并记下")
                    }
                    IconButton(onClick = { launchDriveFolderPicker() }) {
                        Icon(Icons.Default.FolderOpen, contentDescription = "选择云端文件夹")
                    }
                    IconButton(onClick = { scope.launch { syncAndLoad() } }) {
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
                    onClick = { tab = Tab.Backup },
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
                statusMsg?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.55f),
                        modifier = Modifier.padding(vertical = 6.dp),
                    )
                }
            } else {
                Text(
                    "顶栏粘贴，或从其他 App 分享到这里。先保存在本机。",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.55f),
                    modifier = Modifier.padding(vertical = 6.dp),
                )
            }

            if (loading && items.isEmpty() && captures.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            } else if (tab == Tab.Backup) {
                val listState = rememberLazyListState()
                LaunchedEffect(listState, endReached, loading) {
                    snapshotFlow {
                        val info = listState.layoutInfo
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
                LazyColumn(
                    state = listState,
                    contentPadding = PaddingValues(bottom = 24.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    items(items, key = { it.id }) { row ->
                        ItemCard(
                            row = row,
                            repo = app.backupRepo,
                            onClick = { selected = row },
                        )
                    }
                    if (items.isEmpty() && hasRoot) {
                        item {
                            Text("这里还没有条目。点右上角刷新，或确认云端文件夹选对了。", modifier = Modifier.padding(24.dp))
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
    Card(
        onClick = onClick,
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        elevation = CardDefaults.cardElevation(1.dp),
    ) {
        Column(Modifier.padding(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TypeBadge(row.type)
                Spacer(Modifier.width(8.dp))
                Text(
                    row.displayTime,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
                )
                Spacer(Modifier.weight(1f))
                row.sourceApp?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.labelSmall,
                        maxLines = 1,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f),
                    )
                }
            }
            Spacer(Modifier.height(10.dp))
            ListItemBody(row = row, repo = repo)
        }
    }
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
            Spacer(Modifier.height(12.dp))
            Box(Modifier.weight(1f, fill = true).fillMaxWidth()) {
                DetailContent(row = row, repo = repo, modifier = Modifier.fillMaxWidth())
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
