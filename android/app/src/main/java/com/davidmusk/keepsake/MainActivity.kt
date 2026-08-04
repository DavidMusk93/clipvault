package com.davidmusk.keepsake

import android.content.ClipData
import android.content.ClipboardManager
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.davidmusk.keepsake.data.BackupRepository
import com.davidmusk.keepsake.data.ClipboardRow
import com.davidmusk.keepsake.data.LocalCapture
import com.davidmusk.keepsake.ui.theme.KeepsakeTheme
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch


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
                            Toast.makeText(this, "剪贴板为空或不可读（需前台粘贴）", Toast.LENGTH_SHORT).show()
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

    val openTree = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocumentTree()
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
                    Column {
                        Text("Keepsake", fontWeight = FontWeight.SemiBold)
                        Text(
                            "你的剪贴板记忆 · Android",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                        )
                    }
                },
                actions = {
                    IconButton(onClick = {
                        scope.launch {
                            val text = onPasteFromClipboard() ?: return@launch
                            app.captures.insertText(text, source = "paste")
                            captures = app.captures.list()
                            tab = Tab.Captures
                            Toast.makeText(ctx, "已保存到本机捕获", Toast.LENGTH_SHORT).show()
                        }
                    }) {
                        Icon(Icons.Default.ContentPaste, contentDescription = "粘贴保存")
                    }
                    IconButton(onClick = { openTree.launch(null) }) {
                        Icon(Icons.Default.FolderOpen, contentDescription = "选择备份目录")
                    }
                    IconButton(onClick = { scope.launch { syncAndLoad() } }) {
                        Icon(Icons.Default.Refresh, contentDescription = "同步")
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
                SetupCard(onPick = { openTree.launch(null) })
                Spacer(Modifier.height(12.dp))
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(
                    selected = tab == Tab.Backup,
                    onClick = { tab = Tab.Backup },
                    label = { Text("备份") },
                )
                FilterChip(
                    selected = tab == Tab.Captures,
                    onClick = {
                        tab = Tab.Captures
                        scope.launch { captures = app.captures.list() }
                    },
                    label = { Text("本机捕获") },
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
                    "前台粘贴 / 系统分享写入本机队列。上传回 Mac 备份为后续版本。",
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
                        ItemCard(row = row, onClick = { selected = row })
                    }
                    if (items.isEmpty() && hasRoot) {
                        item {
                            Text("备份为空或尚未同步成功", modifier = Modifier.padding(24.dp))
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
                                "还没有本机捕获。点顶栏粘贴，或从其他 App 分享到 Keepsake。",
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
            Text("连接 Mac 备份", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(
                "在文件选择器中打开 Google Drive → My Drive → Keepsake → backup（含 latest/ 与 blobs/ 的那一层）。建议把该文件夹设为离线可用。",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.75f),
            )
            Button(onClick = onPick) {
                Icon(Icons.Default.FolderOpen, null, Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("选择备份目录")
            }
        }
    }
}

@Composable
private fun ItemCard(row: ClipboardRow, onClick: () -> Unit) {
    Card(
        onClick = onClick,
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        elevation = CardDefaults.cardElevation(1.dp),
    ) {
        Column(Modifier.padding(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    row.type.uppercase(),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.primary,
                    fontWeight = FontWeight.Bold,
                )
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
                        overflow = TextOverflow.Ellipsis,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f),
                    )
                }
            }
            Spacer(Modifier.height(6.dp))
            Text(
                row.preview,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
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
    var bytes by remember { mutableStateOf<ByteArray?>(null) }
    var loading by remember { mutableStateOf(row.type == "image") }

    LaunchedEffect(row.id) {
        if (row.type == "image" || row.type == "pdf" || row.type == "rtf") {
            loading = true
            bytes = repo.loadPayload(row)
            loading = false
        }
    }

    val textBody = row.textContent ?: row.url ?: row.ocrText ?: row.htmlContent

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(row.type) },
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
                },
            )
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp),
        ) {
            Text(
                "${row.displayTime} · ${row.sourceApp ?: "未知来源"}",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.55f),
            )
            Spacer(Modifier.height(12.dp))
            if (loading) {
                CircularProgressIndicator()
            } else if (row.type == "image" && bytes != null) {
                val bmp = remember(bytes) {
                    bytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size)?.asImageBitmap() }
                }
                if (bmp != null) {
                    Image(
                        bitmap = bmp,
                        contentDescription = null,
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(320.dp),
                        contentScale = ContentScale.Fit,
                    )
                }
                row.ocrText?.takeIf { it.isNotBlank() }?.let {
                    Spacer(Modifier.height(12.dp))
                    Text("OCR", fontWeight = FontWeight.SemiBold)
                    Text(it)
                }
            } else {
                Text(
                    textBody ?: "（无文本内容）",
                    style = MaterialTheme.typography.bodyLarge,
                )
            }
            if (!textBody.isNullOrBlank()) {
                Spacer(Modifier.height(16.dp))
                Button(onClick = { onCopy(textBody) }, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Default.ContentCopy, null)
                    Spacer(Modifier.width(8.dp))
                    Text("复制到剪贴板")
                }
            }
        }
    }
}
