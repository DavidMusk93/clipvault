package com.davidmusk.keepsake.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val Honey = Color(0xFFC47A2C)
private val Cream = Color(0xFFF8F1E7)
private val Ink = Color(0xFF1C1410)

private val LightColors = lightColorScheme(
    primary = Honey,
    onPrimary = Color.White,
    secondary = Color(0xFF5C4A3A),
    background = Cream,
    surface = Color.White,
    onBackground = Ink,
    onSurface = Ink,
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFFE0A45A),
    onPrimary = Ink,
    secondary = Color(0xFFD4C4B0),
    background = Color(0xFF16110E),
    surface = Color(0xFF221A15),
    onBackground = Cream,
    onSurface = Cream,
)

@Composable
fun KeepsakeTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    MaterialTheme(
        colorScheme = if (dark) DarkColors else LightColors,
        content = content,
    )
}
