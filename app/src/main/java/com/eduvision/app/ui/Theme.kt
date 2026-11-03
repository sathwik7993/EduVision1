package com.eduvision.app.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val Indigo = Color(0xFF3F51B5)
private val Teal = Color(0xFF00897B)

val Good = Color(0xFF2E7D32)
val Warn = Color(0xFFB26A00)

@Composable
fun EduTheme(content: @Composable () -> Unit) {
    val colors = if (isSystemInDarkTheme()) {
        darkColorScheme(primary = Color(0xFF9FA8DA), secondary = Color(0xFF80CBC4), background = Color(0xFF101318), surface = Color(0xFF161A21))
    } else {
        lightColorScheme(primary = Indigo, secondary = Teal, background = Color(0xFFF7F8FB), surface = Color.White)
    }
    MaterialTheme(colorScheme = colors, content = content)
}
