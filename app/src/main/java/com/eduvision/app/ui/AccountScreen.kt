package com.eduvision.app.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.eduvision.app.BuildConfig
import com.eduvision.app.EduApp
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountScreen(app: EduApp, onBack: () -> Unit) {
    val user = app.auth.currentUser
    val scope = rememberCoroutineScope()
    var message by remember { mutableStateOf<String?>(null) }
    Scaffold(topBar = {
        TopAppBar(title = { Text("Account") }, navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } })
    }) { pad ->
        Column(Modifier.fillMaxSize().padding(pad).padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(user?.email ?: user?.displayName ?: "Signed in", style = MaterialTheme.typography.titleLarge)
            Text("Scans, results, layouts and the class list are stored only on this phone. " +
                "Signing out keeps them.", style = MaterialTheme.typography.bodyMedium)
            if (user?.email != null && user.providerData.any { it.providerId == "password" }) {
                OutlinedButton({
                    scope.launch {
                        message = try { app.auth.resetPassword(user.email!!); "Password reset email sent." } catch (e: Exception) { e.message }
                    }
                }, Modifier.fillMaxWidth()) { Text("Change password") }
            }
            Button({ app.auth.signOut() }, Modifier.fillMaxWidth()) { Text("Sign out") }
            message?.let { Text(it) }
            Text("EduVision ${BuildConfig.VERSION_NAME}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
