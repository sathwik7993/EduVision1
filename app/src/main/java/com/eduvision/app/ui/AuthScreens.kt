package com.eduvision.app.ui

import android.app.Activity
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.eduvision.app.R
import com.eduvision.app.data.AuthCancelled
import com.eduvision.app.data.AuthService
import kotlinx.coroutines.launch

@Composable
private fun AuthFrame(title: String, subtitle: String, content: @Composable () -> Unit) {
    Column(
        Modifier.fillMaxSize().systemBarsPadding().imePadding().verticalScroll(rememberScrollState()).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Spacer(Modifier.height(24.dp))
        Image(painterResource(R.drawable.eduicon), contentDescription = null, Modifier.size(88.dp))
        Text(title, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
        Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(8.dp))
        content()
    }
}

@Composable
fun LoginScreen(auth: AuthService, onRegister: () -> Unit) {
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current

    fun run(block: suspend () -> Unit) {
        busy = true; message = null
        scope.launch {
            try { block() } catch (_: AuthCancelled) { } catch (e: Exception) { message = e.message }
            busy = false
        }
    }

    AuthFrame("EduVision", "Scan exam sheets, check the marks, export to Excel.") {
        OutlinedTextField(email, { email = it }, label = { Text("Email") }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email), modifier = Modifier.fillMaxWidth().testTag("email"))
        OutlinedTextField(password, { password = it }, label = { Text("Password") }, singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password), modifier = Modifier.fillMaxWidth().testTag("password"))
        message?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        Button({ run { auth.signIn(email, password) } }, enabled = !busy, modifier = Modifier.fillMaxWidth().height(48.dp)) {
            if (busy) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp) else Text("Sign in")
        }
        OutlinedButton({ run { auth.signInWithGoogle(context as Activity) } }, enabled = !busy, modifier = Modifier.fillMaxWidth().height(48.dp)) {
            Image(painterResource(R.drawable.google_logo), contentDescription = null, Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text("Continue with Google")
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton({ run { auth.resetPassword(email); message = "Password reset email sent to $email." } }) { Text("Forgot password?") }
            TextButton(onRegister) { Text("Create an account") }
        }
    }
}

@Composable
fun RegisterScreen(auth: AuthService, onBack: () -> Unit) {
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    AuthFrame("Create account", "One account per teacher. Your scans stay on this phone.") {
        OutlinedTextField(email, { email = it }, label = { Text("Email") }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email), modifier = Modifier.fillMaxWidth())
        OutlinedTextField(password, { password = it }, label = { Text("Password") }, singleLine = true,
            visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
        OutlinedTextField(confirm, { confirm = it }, label = { Text("Confirm password") }, singleLine = true,
            visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
        message?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        Button({
            busy = true; message = null
            scope.launch {
                try { auth.register(email, password, confirm) } catch (e: Exception) { message = e.message }
                busy = false
            }
        }, enabled = !busy, modifier = Modifier.fillMaxWidth().height(48.dp)) {
            if (busy) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp) else Text("Create account")
        }
        TextButton(onBack) { Text("I already have an account") }
    }
}
