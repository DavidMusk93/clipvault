package com.davidmusk.keepsake.data

import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import androidx.core.text.HtmlCompat

/**
 * Read the system clipboard with the same type preference as Mac Keepsake:
 * HTML (rich) → plain/url text → uri string.
 *
 * Android does not expose RTF the way AppKit does; HTML is the rich path.
 */
data class CapturedClip(
    val type: String,
    val text: String,
    val html: String? = null,
)

object ClipboardReader {
    fun read(context: Context): CapturedClip? {
        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: return null
        val clip = cm.primaryClip ?: return null
        if (clip.itemCount <= 0) return null
        val item = clip.getItemAt(0)
        val desc = clip.description

        // Prefer explicit HTML mime when present.
        val htmlText = try {
            item.htmlText?.takeIf { it.isNotBlank() }
        } catch (_: Throwable) {
            null
        }
        val hasHtmlMime = (0 until desc.mimeTypeCount).any {
            val m = desc.getMimeType(it)
            m == ClipDescription.MIMETYPE_TEXT_HTML || m.contains("html", ignoreCase = true)
        }
        if (!htmlText.isNullOrBlank() && (hasHtmlMime || looksLikeHtml(htmlText))) {
            val plain = item.text?.toString()?.takeIf { it.isNotBlank() }
                ?: htmlToPlain(htmlText)
            if (plain.isBlank()) return null
            val type = when {
                plain.startsWith("http://") || plain.startsWith("https://") -> "url"
                else -> "html"
            }
            return CapturedClip(type = type, text = plain, html = htmlText)
        }

        val plain = item.coerceToText(context)?.toString()?.takeIf { it.isNotBlank() }
        if (plain != null) {
            val type = when {
                plain.startsWith("http://") || plain.startsWith("https://") -> "url"
                else -> "text"
            }
            return CapturedClip(type = type, text = plain, html = null)
        }

        val uri = item.uri
        if (uri != null) {
            return CapturedClip(type = "url", text = uri.toString(), html = null)
        }
        return null
    }

    private fun looksLikeHtml(s: String): Boolean {
        val t = s.trimStart().lowercase()
        return t.startsWith("<!doctype html") || t.startsWith("<html") ||
            t.contains("<body") || t.contains("<p") || t.contains("<div")
    }

    fun htmlToPlain(html: String): String {
        return HtmlCompat.fromHtml(html, HtmlCompat.FROM_HTML_MODE_COMPACT)
            .toString()
            .replace('\u00A0', ' ')
            .replace("\u200B", "")
            .trim()
    }
}
