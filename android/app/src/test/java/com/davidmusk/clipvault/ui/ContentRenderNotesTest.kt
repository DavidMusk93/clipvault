package com.davidmusk.clipvault.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM gate for the Android detail WebView fragment policy.
 * Mirrors the web allowlist: no active content, no navigable links, no remote media.
 */
class ContentRenderNotesTest {

    private fun frag(html: String) = notesHtmlFragment(html)

    @Test
    fun `drops active and remote tags`() {
        val cases = listOf(
            "<p>x</p><script>alert(1)</script>",
            "<svg onload=alert(1)><image href=\"https://evil/x.png\"></image></svg>",
            "<math><mtext><img src=x onerror=alert(1)></mtext></math>",
            "<iframe src=\"https://evil\"></iframe>",
            "<audio src=\"https://evil/a.mp3\"></audio>",
            "<video src=\"https://evil/v.mp4\"></video>",
            "<input type=\"image\" src=\"https://evil/y.png\">",
            "<form action=\"https://evil\"><button formaction=\"https://evil\">go</button></form>",
        )
        for (input in cases) {
            val out = frag(input)
            assertFalse(
                "active tag survived: $out",
                Regex("(?i)<(script|svg|math|iframe|audio|video|input|form|button|object|embed|style)\\b").containsMatchIn(out),
            )
            assertFalse(
                "fetch/nav attribute survived: $out",
                Regex("(?i)\\b(src|href|srcset|formaction|srcdoc|action)\\s*=").containsMatchIn(out),
            )
        }
    }

    @Test
    fun `removes inline event handlers`() {
        val out = frag("<div onclick=\"alert(1)\">c</div><marquee onstart=alert(2)>m</marquee>")
        assertFalse(out, Regex("(?i)\\son[a-z]+\\s*=").containsMatchIn(out))
        assertTrue(out, out.contains("c"))
    }

    @Test
    fun `neutralizes anchors to inert spans`() {
        val out = frag("<p>see <a href=\"https://example.com/x\">link</a></p>")
        assertFalse(out, out.contains("<a"))
        assertTrue(out, out.contains("url-inert"))
        assertTrue(out, out.contains("link"))
    }

    @Test
    fun `replaces images with layout-stable placeholders`() {
        val out = frag("<p>pic <img src=\"https://evil/x.png\" alt=\"cover\"> done</p>")
        assertFalse(out, Regex("(?i)<img\\b").containsMatchIn(out))
        assertTrue(out, out.contains("html-img-ph"))
        assertTrue(out, out.contains("cover"))
    }

    @Test
    fun `drops presentation attributes but keeps structural ones`() {
        val out = frag(
            "<table width=\"500\"><tr><td colspan=\"2\" rowspan=\"3\" style='border:1px' bgcolor=\"#000\">cell</td></tr></table>",
        )
        assertTrue(out, out.contains("<table"))
        assertTrue(out, out.contains("colspan=\"2\""))
        assertTrue(out, out.contains("rowspan=\"3\""))
        assertFalse(out, Regex("(?i)width\\s*=").containsMatchIn(out))
        assertFalse(out, Regex("(?i)bgcolor").containsMatchIn(out))
        assertFalse(out, Regex("(?i)style\\s*=").containsMatchIn(out))
    }

    @Test
    fun `strips single-quoted style and class`() {
        val out = frag("<span class='x' style='background:black;color:white'>DSOD</span>")
        assertFalse(out, Regex("(?i)style\\s*=").containsMatchIn(out))
        assertFalse(out, Regex("(?i)class\\s*=").containsMatchIn(out))
        assertTrue(out, out.contains("DSOD"))
    }

    @Test
    fun `unwraps Apple converted space`() {
        val out = frag("<p>a<span class=\"Apple-converted-space\">&nbsp;</span>b</p>")
        assertFalse(out, out.contains("Apple-converted-space"))
        assertTrue(out, out.contains("a"))
        assertTrue(out, out.contains("b"))
    }
}
