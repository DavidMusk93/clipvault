package com.davidmusk.keepsake.share

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import com.davidmusk.keepsake.keepsake
import kotlinx.coroutines.launch

/**
 * System share → local capture queue (text only for v0.1).
 */
class ShareReceiverActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val intent = intent
        val text = when {
            intent?.action != Intent.ACTION_SEND -> null
            intent.type?.startsWith("text/") == true ->
                intent.getStringExtra(Intent.EXTRA_TEXT)
            else -> intent.getStringExtra(Intent.EXTRA_TEXT)
        }
        if (text.isNullOrBlank()) {
            Toast.makeText(this, "暂仅支持分享文本", Toast.LENGTH_SHORT).show()
            finish()
            return
        }
        lifecycleScope.launch {
            application.keepsake.captures.insertText(text, source = "share")
            Toast.makeText(this@ShareReceiverActivity, "已保存到 Keepsake", Toast.LENGTH_SHORT).show()
            finish()
        }
    }
}
