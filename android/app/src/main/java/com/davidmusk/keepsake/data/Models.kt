package com.davidmusk.keepsake.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

data class ClipboardRow(
    val id: String,
    val timestamp: Double,
    val type: String,
    val contentHash: String,
    val textContent: String?,
    val url: String?,
    val htmlContent: String?,
    val sourceApp: String?,
    val ocrText: String?,
    val copyCount: Int,
    val fileUrls: String?,
    /** Soft-delete unix seconds; null = alive. */
    val deletedAt: Double? = null,
    /** First capture event unix seconds. */
    val firstSeenAt: Double? = null,
) {
    val inTrash: Boolean get() = deletedAt != null

    val preview: String
        get() {
            val raw = when (type) {
                "text", "url" -> textContent ?: url ?: ""
                "image" -> ocrText?.takeIf { it.isNotBlank() } ?: "图片"
                "rtf" -> textContent ?: "富文本"
                "html" -> htmlContent?.replace(Regex("<[^>]+>"), "")?.trim().orEmpty()
                    .ifBlank { "HTML" }
                "pdf" -> "PDF"
                "file" -> fileUrls ?: "文件"
                else -> textContent ?: type
            }
            return raw.replace("\n", " ").trim().take(160).ifBlank { "（无预览）" }
        }

    val displayTime: String
        get() = formatLocalUnix(timestamp)

    val displayFirstSeen: String?
        get() = firstSeenAt?.let { formatLocalUnix(it) }

    val displayDeletedAt: String?
        get() = deletedAt?.let { formatLocalUnix(it) }
}

data class ClipEvent(
    val id: String,
    val itemId: String,
    val contentHash: String,
    val eventTs: Double,
    val type: String,
    val sourceApp: String?,
    val kind: String,
) {
    val displayTime: String get() = formatLocalUnix(eventTs)
}

data class OperationLog(
    val id: String,
    val ts: Double,
    val action: String,
    val itemId: String?,
    val contentHash: String?,
    val detail: String?,
    val source: String,
) {
    val displayTime: String get() = formatLocalUnix(ts)
}

@Serializable
data class BackupManifest(
    val version: Int? = null,
    val sha256: String? = null,
    val itemCount: Int? = null,
    val byteSize: Long? = null,
    val blobCount: Int? = null,
    val blobBytes: Long? = null,
    val createdAt: String? = null,
    val createdAtUnix: Double? = null,
    val engine: String? = null,
    val host: String? = null,
    val note: String? = null,
    /** Filenames under blobs/ when Mac published this snapshot (Drive completeness check). */
    val blobFiles: List<String>? = null,
    val blobsVerified: Boolean? = null,
)

@Serializable
data class BackupStatusFile(
    val scheme: String? = null,
    val enabled: Boolean? = null,
    val lastSuccessAt: String? = null,
    val lastPhase: String? = null,
    val policy: String? = null,
    val googleDriveAvailable: Boolean? = null,
    val latest: LatestInfo? = null,
) {
    @Serializable
    data class LatestInfo(
        val sha256: String? = null,
        val itemCount: Int? = null,
        val byteSize: Long? = null,
        @SerialName("createdAt") val createdAt: String? = null,
    )
}

data class LocalCapture(
    val id: String,
    val type: String,
    val text: String?,
    val contentHash: String,
    val createdAtMs: Long,
    val source: String,
    val htmlContent: String? = null,
) {
    val preview: String
        get() {
            val raw = text ?: htmlContent?.replace(Regex("<[^>]+>"), "") ?: type
            return raw.replace("\n", " ").trim().take(160).ifBlank { type }
        }

    val displayTime: String
        get() {
            val fmt = SimpleDateFormat("yyyy/MM/dd HH:mm:ss", Locale.getDefault())
            return fmt.format(Date(createdAtMs))
        }
}

/** Display zone: device default, but never silent UTC for CN users. */
fun displayTimeZone(): TimeZone {
    val def = TimeZone.getDefault()
    if (def.rawOffset == 0 && (def.id == "UTC" || def.id == "GMT" || def.id.startsWith("Etc/UTC"))) {
        return TimeZone.getTimeZone("Asia/Shanghai")
    }
    return def
}

fun formatLocalUnix(seconds: Double): String {
    val ms = (seconds * 1000.0).toLong()
    val fmt = SimpleDateFormat("yyyy/MM/dd HH:mm:ss", Locale.getDefault())
    fmt.timeZone = displayTimeZone()
    return fmt.format(Date(ms))
}

/**
 * Display wire instants (unix seconds or ISO-8601) in the device local zone.
 * Accepts `…Z`, `…+08:00`, and legacy bare ISO (treated as UTC).
 */
fun formatDisplayInstant(raw: String?): String {
    if (raw.isNullOrBlank()) return "—"
    val s = raw.trim()
    s.toDoubleOrNull()?.let { return formatLocalUnix(it) }
    return try {
        val normalized = when {
            s.endsWith("Z", ignoreCase = true) || Regex("[+-]\\d{2}:?\\d{2}$").containsMatchIn(s) -> s
            s.contains('T') -> s + "Z" // legacy STATUS.json UTC without offset
            else -> s
        }
        // java.time is preferred but API may be older; SimpleDateFormat multi-pattern.
        val patterns = arrayOf(
            "yyyy-MM-dd'T'HH:mm:ssX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSX",
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            "yyyy-MM-dd HH:mm:ss",
        )
        var parsed: Date? = null
        for (p in patterns) {
            try {
                val fmt = SimpleDateFormat(p, Locale.US)
                if (p.contains("X") || p.contains("'Z'")) {
                    fmt.timeZone = TimeZone.getTimeZone("UTC")
                } else {
                    fmt.timeZone = TimeZone.getDefault()
                }
                // For patterns with X, zone is in string; UTC default is fine as base.
                parsed = fmt.parse(normalized)
                if (parsed != null) break
            } catch (_: Exception) {
            }
        }
        if (parsed == null) return s
        val out = SimpleDateFormat("yyyy/MM/dd HH:mm:ss", Locale.getDefault())
        out.timeZone = displayTimeZone()
        out.format(parsed)
    } catch (_: Exception) {
        s
    }
}

/** Wire ISO with local offset (not bare Z mislabel). */
fun isoNow(): String {
    val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US)
    fmt.timeZone = displayTimeZone()
    return fmt.format(Date())
}
