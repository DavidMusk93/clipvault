package com.davidmusk.keepsake.ui

import android.graphics.BitmapFactory
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.text.method.LinkMovementMethod
import android.util.TypedValue
import android.view.ViewGroup
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.TextView
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.clickable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.TextFields
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.text.HtmlCompat
import com.davidmusk.keepsake.data.BackupRepository
import com.davidmusk.keepsake.data.ClipboardRow
import java.io.File
import java.io.FileOutputStream

data class TypeStyle(
    val label: String,
    val icon: ImageVector,
    val color: Color,
)

fun typeStyle(type: String): TypeStyle = when (type.lowercase()) {
    "image" -> TypeStyle("图片", Icons.Default.Image, Color(0xFF2E7D32))
    "url" -> TypeStyle("链接", Icons.Default.Link, Color(0xFF1565C0))
    "html" -> TypeStyle("HTML", Icons.Default.Code, Color(0xFF6A1B9A))
    "rtf" -> TypeStyle("富文本", Icons.Default.Description, Color(0xFFEF6C00))
    "pdf" -> TypeStyle("PDF", Icons.Default.PictureAsPdf, Color(0xFFC62828))
    "text" -> TypeStyle("文本", Icons.Default.TextFields, Color(0xFFC47A2C))
    else -> TypeStyle(type.uppercase(), Icons.Default.Description, Color(0xFF5D4037))
}

@Composable
fun TypeBadge(type: String, modifier: Modifier = Modifier) {
    val style = typeStyle(type)
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(8.dp),
        color = style.color.copy(alpha = 0.12f),
    ) {
        Row(
            Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Icon(style.icon, null, Modifier.size(14.dp), tint = style.color)
            Text(
                style.label,
                style = MaterialTheme.typography.labelSmall,
                color = style.color,
                fontWeight = FontWeight.SemiBold,
            )
        }
    }
}

/** Result of async image load: bitmap, loading flag, failed flag, and retry trigger. */
data class PayloadBitmapState(
    val bitmap: androidx.compose.ui.graphics.ImageBitmap?,
    val loading: Boolean,
    val failed: Boolean,
    val retry: () -> Unit,
)

/**
 * Async load blob → ImageBitmap with retry.
 * [maxSideDp] is density-aware so xxhdpi/xxxhdpi stay sharp.
 * Drive lag / SAF blips surface as [PayloadBitmapState.failed] instead of silent empty.
 */
@Composable
fun rememberPayloadBitmap(
    row: ClipboardRow,
    repo: BackupRepository,
    enabled: Boolean = row.type == "image",
    maxSideDp: Dp = 360.dp,
): PayloadBitmapState {
    val density = LocalDensity.current
    val maxSidePx = with(density) { maxSideDp.roundToPx() }.coerceIn(128, 4096)
    var bmp by remember(row.id) { mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null) }
    var loading by remember(row.id) { mutableStateOf(enabled) }
    var failed by remember(row.id) { mutableStateOf(false) }
    var retryToken by remember(row.id) { mutableIntStateOf(0) }
    LaunchedEffect(row.id, enabled, maxSidePx, retryToken) {
        if (!enabled) {
            loading = false
            failed = false
            return@LaunchedEffect
        }
        loading = true
        failed = false
        val decoded = repo.loadImageBitmap(row, maxSidePx)?.asImageBitmap()
        bmp = decoded
        failed = decoded == null
        loading = false
    }
    return PayloadBitmapState(
        bitmap = bmp,
        loading = loading,
        failed = failed,
        retry = { retryToken += 1 },
    )
}

/** Keep masonry heights sane for extreme panoramic / ultra-tall shots. */
private fun displayAspect(width: Int, height: Int): Float {
    if (width <= 0 || height <= 0) return 1f
    return (width.toFloat() / height.toFloat()).coerceIn(0.52f, 1.85f)
}

@Composable
fun ListItemBody(
    row: ClipboardRow,
    repo: BackupRepository,
    modifier: Modifier = Modifier,
) {
    when (row.type.lowercase()) {
        "image" -> {
            // Natural aspect + density-aware decode; tap to retry on Drive lag.
            val state = rememberPayloadBitmap(row, repo, maxSideDp = 280.dp)
            val bmp = state.bitmap
            Column(modifier = modifier.fillMaxWidth()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .then(
                            if (bmp != null) {
                                Modifier.aspectRatio(displayAspect(bmp.width, bmp.height))
                            } else {
                                Modifier.aspectRatio(1f)
                            },
                        )
                        .clip(RoundedCornerShape(10.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                        .then(
                            if (state.failed && !state.loading) {
                                Modifier.clickable { state.retry() }
                            } else {
                                Modifier
                            },
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    when {
                        state.loading -> CircularProgressIndicator(
                            modifier = Modifier.size(22.dp),
                            strokeWidth = 2.dp,
                        )
                        bmp != null -> Image(
                            bitmap = bmp,
                            contentDescription = "图片预览",
                            modifier = Modifier.fillMaxWidth(),
                            contentScale = ContentScale.Crop,
                            filterQuality = FilterQuality.High,
                        )
                        else -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Icon(
                                imageVector = Icons.Default.Refresh,
                                contentDescription = "重试加载",
                                modifier = Modifier.size(26.dp),
                                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.65f),
                            )
                            Spacer(Modifier.height(4.dp))
                            Text(
                                "点按重试",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.65f),
                            )
                        }
                    }
                }
                val caption = row.ocrText?.takeIf { it.isNotBlank() }
                if (caption != null) {
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = caption.replace("\n", " ").trim(),
                        style = MaterialTheme.typography.bodySmall,
                        maxLines = 4,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
        "url" -> {
            val url = row.url ?: row.textContent.orEmpty()
            Column(modifier) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.Default.Link,
                        null,
                        Modifier.size(16.dp),
                        tint = MaterialTheme.colorScheme.primary,
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        url,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.primary,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
        "html" -> {
            val plain = stripHtml(row.htmlContent ?: row.textContent.orEmpty())
            Text(
                plain.ifBlank { "HTML 内容" },
                modifier = modifier,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
        }
        "rtf" -> {
            Text(
                (row.textContent ?: row.ocrText ?: "富文本").replace("\n", " "),
                modifier = modifier,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
        }
        "pdf" -> {
            Row(modifier, verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.PictureAsPdf, null, tint = Color(0xFFC62828))
                Spacer(Modifier.width(8.dp))
                Text(
                    row.textContent ?: "PDF 文档",
                    style = MaterialTheme.typography.bodyMedium,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        else -> {
            Text(
                row.preview,
                modifier = modifier,
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 4,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
fun DetailContent(
    row: ClipboardRow,
    repo: BackupRepository,
    modifier: Modifier = Modifier,
) {
    val scroll = rememberScrollState()
    Column(
        modifier
            .fillMaxWidth()
            .verticalScroll(scroll),
    ) {
        when (row.type.lowercase()) {
            "image" -> DetailImage(row, repo)
            "html" -> DetailHtml(row.htmlContent ?: row.textContent.orEmpty())
            "rtf" -> DetailRtf(row, repo)
            "url" -> DetailUrl(row)
            "pdf" -> DetailPdf(row, repo)
            else -> DetailPlainText(
                row.textContent ?: row.ocrText ?: row.htmlContent ?: "（无文本内容）"
            )
        }
    }
}

@Composable
private fun DetailImage(row: ClipboardRow, repo: BackupRepository) {
    // Full-width decode ≈ screen width * density (sharp on 3x/4x panels).
    val state = rememberPayloadBitmap(row, repo, enabled = true, maxSideDp = 720.dp)
    val bmp = state.bitmap
    if (state.loading) {
        Box(Modifier.fillMaxWidth().height(200.dp), contentAlignment = Alignment.Center) {
            CircularProgressIndicator()
        }
        return
    }
    if (bmp != null) {
        val aspect = displayAspect(bmp.width, bmp.height)
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(aspect)
                .clip(RoundedCornerShape(12.dp))
                .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(12.dp))
                .background(Color(0xFF121212)),
            contentAlignment = Alignment.Center,
        ) {
            Image(
                bitmap = bmp,
                contentDescription = "图片",
                modifier = Modifier.fillMaxWidth(),
                contentScale = ContentScale.Fit,
                filterQuality = FilterQuality.High,
            )
        }
    } else {
        Column {
            Text("图片加载失败", color = MaterialTheme.colorScheme.error)
            Spacer(Modifier.height(6.dp))
            Text(
                "云端可能还在同步，或网络中断。点下方重试。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.65f),
            )
            Spacer(Modifier.height(8.dp))
            Surface(
                shape = RoundedCornerShape(8.dp),
                color = MaterialTheme.colorScheme.primary.copy(alpha = 0.12f),
                modifier = Modifier.clickable { state.retry() },
            ) {
                Row(
                    Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Default.Refresh, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.primary)
                    Spacer(Modifier.width(6.dp))
                    Text("重新加载", color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.Medium)
                }
            }
        }
    }
    row.ocrText?.takeIf { it.isNotBlank() }?.let { ocr ->
        Spacer(Modifier.height(16.dp))
        Text("识别文字", fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(6.dp))
        SelectionContainer {
            Text(ocr, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

@Composable
private fun DetailHtml(html: String) {
    if (html.isBlank()) {
        Text("（空 HTML）")
        return
    }
    // Prefer native HTML spans for simple docs; WebView for richer markup.
    val rich = html.contains("<img", ignoreCase = true) ||
        html.contains("<table", ignoreCase = true) ||
        html.contains("<style", ignoreCase = true)
    if (rich) {
        AndroidView(
            factory = { ctx ->
                WebView(ctx).apply {
                    layoutParams = ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.WRAP_CONTENT,
                    )
                    settings.javaScriptEnabled = false
                    settings.defaultTextEncodingName = "utf-8"
                    webViewClient = WebViewClient()
                    setBackgroundColor(android.graphics.Color.TRANSPARENT)
                    val wrapped = """
                        <!DOCTYPE html><html><head>
                        <meta name="viewport" content="width=device-width,initial-scale=1"/>
                        <style>
                          body{font-family:-apple-system,sans-serif;font-size:15px;line-height:1.55;
                               color:#1C1410;margin:0;padding:4px 2px;word-wrap:break-word;}
                          img{max-width:100%;height:auto;border-radius:8px;}
                          a{color:#C47A2C;}
                          pre,code{font-family:ui-monospace,monospace;font-size:13px;
                                   background:#F3EBE0;padding:2px 4px;border-radius:4px;}
                          pre{padding:10px;overflow:auto;}
                        </style></head><body>$html</body></html>
                    """.trimIndent()
                    loadDataWithBaseURL(null, wrapped, "text/html", "utf-8", null)
                }
            },
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 120.dp, max = 640.dp)
                .clip(RoundedCornerShape(10.dp)),
        )
    } else {
        HtmlTextBlock(html)
    }
}

@Composable
private fun HtmlTextBlock(html: String) {
    val context = LocalContext.current
    val spanned = remember(html) {
        HtmlCompat.fromHtml(html, HtmlCompat.FROM_HTML_MODE_COMPACT)
    }
    AndroidView(
        factory = { ctx ->
            TextView(ctx).apply {
                setTextIsSelectable(true)
                movementMethod = LinkMovementMethod.getInstance()
                setTextColor(android.graphics.Color.parseColor("#1C1410"))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
                setLineSpacing(0f, 1.25f)
            }
        },
        update = { it.text = spanned },
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun DetailRtf(row: ClipboardRow, repo: BackupRepository) {
    // Prefer extracted plain text; otherwise try HTML field; show payload size tip.
    val plain = row.textContent?.takeIf { it.isNotBlank() }
        ?: row.htmlContent?.let { stripHtml(it) }?.takeIf { it.isNotBlank() }
    if (!plain.isNullOrBlank()) {
        DetailPlainText(plain)
        return
    }
    var info by remember { mutableStateOf("加载富文本…") }
    LaunchedEffect(row.id) {
        val bytes = repo.loadPayload(row)
        info = if (bytes == null) {
            "无法加载富文本附件"
        } else {
            "富文本（RTF）· ${bytes.size / 1024} KB\n\n当前仅预览元数据；若电脑端已抽出纯文本会显示在此。"
        }
    }
    Text(info, style = MaterialTheme.typography.bodyMedium)
}

@Composable
private fun DetailUrl(row: ClipboardRow) {
    val url = row.url ?: row.textContent.orEmpty()
    SelectionContainer {
        Text(
            url,
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.primary,
        )
    }
    row.textContent?.takeIf { it != url && it.isNotBlank() }?.let {
        Spacer(Modifier.height(12.dp))
        DetailPlainText(it)
    }
}

@Composable
private fun DetailPdf(row: ClipboardRow, repo: BackupRepository) {
    val context = LocalContext.current
    var pageBmp by remember { mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null) }
    var status by remember { mutableStateOf("加载 PDF…") }
    LaunchedEffect(row.id) {
        val bytes = repo.loadPayload(row)
        if (bytes == null) {
            status = "无法加载 PDF"
            return@LaunchedEffect
        }
        try {
            val tmp = File(context.cacheDir, "preview_${row.id}.pdf")
            FileOutputStream(tmp).use { it.write(bytes) }
            val pfd = ParcelFileDescriptor.open(tmp, ParcelFileDescriptor.MODE_READ_ONLY)
            val renderer = PdfRenderer(pfd)
            if (renderer.pageCount > 0) {
                val page = renderer.openPage(0)
                val bmp = android.graphics.Bitmap.createBitmap(
                    page.width * 2,
                    page.height * 2,
                    android.graphics.Bitmap.Config.ARGB_8888,
                )
                page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                page.close()
                pageBmp = bmp.asImageBitmap()
                status = "PDF · ${renderer.pageCount} 页 · 首页预览"
            } else {
                status = "空 PDF"
            }
            renderer.close()
            pfd.close()
        } catch (e: Exception) {
            status = "PDF 预览失败：${e.message}"
        }
    }
    Text(status, style = MaterialTheme.typography.labelMedium)
    Spacer(Modifier.height(8.dp))
    pageBmp?.let {
        Image(
            bitmap = it,
            contentDescription = "PDF 预览",
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(10.dp)),
            contentScale = ContentScale.FillWidth,
        )
    }
}

@Composable
private fun DetailPlainText(text: String) {
    SelectionContainer {
        Text(
            text,
            style = MaterialTheme.typography.bodyLarge.copy(
                fontFamily = if (looksLikeCode(text)) FontFamily.Monospace else FontFamily.Default,
            ),
        )
    }
}

private fun looksLikeCode(text: String): Boolean {
    val t = text.trim()
    return t.startsWith("{") || t.startsWith("[") || t.contains(":\n") && t.contains("  ") ||
        t.lines().size > 3 && t.lines().count { it.startsWith(" ") || it.startsWith("\t") } > 1
}

fun stripHtml(html: String): String {
    return HtmlCompat.fromHtml(html, HtmlCompat.FROM_HTML_MODE_COMPACT)
        .toString()
        .replace('\u00A0', ' ')
        .trim()
}
