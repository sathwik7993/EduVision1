package com.eduvision.app.ui

import android.app.Activity
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.DocumentScanner
import androidx.compose.material.icons.filled.GridOn
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.ViewQuilt
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.LifecycleResumeEffect
import com.eduvision.app.EduApp
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult
import java.io.File

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    app: EduApp,
    scan: ScanViewModel,
    onReview: () -> Unit,
    onResults: () -> Unit,
    onTemplates: () -> Unit,
    onAccount: () -> Unit,
) {
    val context = LocalContext.current
    var saved by remember { mutableIntStateOf(0) }
    var layout by remember { mutableStateOf<String?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    var cameraUri by remember { mutableStateOf<Uri?>(null) }

    LifecycleResumeEffect(Unit) {
        saved = app.results.all().size
        layout = app.templates.active()?.name
        onPauseOrDispose { }
    }

    val scanner = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { res ->
        if (res.resultCode == Activity.RESULT_OK) {
            GmsDocumentScanningResult.fromActivityResultIntent(res.data)?.pages?.firstOrNull()?.imageUri?.let(scan::process)
        }
    }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
        if (ok) cameraUri?.let(scan::process)
    }
    val gallery = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri?.let(scan::process)
    }

    fun startDocumentScanner() {
        val options = GmsDocumentScannerOptions.Builder()
            .setGalleryImportAllowed(true)
            .setPageLimit(1)
            .setResultFormats(GmsDocumentScannerOptions.RESULT_FORMAT_JPEG)
            .setScannerMode(GmsDocumentScannerOptions.SCANNER_MODE_BASE)
            .build()
        GmsDocumentScanning.getClient(options).getStartScanIntent(context as Activity)
            .addOnSuccessListener { scanner.launch(IntentSenderRequest.Builder(it).build()) }
            // Play services' scanner module missing or not downloadable: fall back.
            .addOnFailureListener { notice = "The document scanner is not available on this phone. Use Camera or Gallery." }
    }

    fun startCamera() {
        val dir = File(context.cacheDir, "camera").apply { mkdirs() }
        val f = File(dir, "photo_${System.currentTimeMillis()}.jpg")
        cameraUri = FileProvider.getUriForFile(context, "${context.packageName}.files", f)
        camera.launch(cameraUri!!)
    }

    LaunchedEffect(scan.state) {
        if (scan.state is ScanViewModel.State.Ready) onReview()
    }

    Scaffold(topBar = {
        TopAppBar(title = { Text("EduVision", fontWeight = FontWeight.Bold) }, actions = {
            IconButton(onAccount) { Icon(Icons.Default.AccountCircle, contentDescription = "Account") }
        })
    }) { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Scan an exam sheet", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                    Text(
                        if (layout == null) "The first sheet teaches the app your college's layout from its printed labels. No setup needed."
                        else "Layout: $layout. A new layout is learned automatically.",
                        style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    when (val s = scan.state) {
                        ScanViewModel.State.Working -> Row(verticalAlignment = Alignment.CenterVertically) {
                            CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 3.dp)
                            Spacer(Modifier.width(12.dp))
                            Text("Reading the sheet...")
                        }
                        is ScanViewModel.State.Failed -> Text(s.message, color = MaterialTheme.colorScheme.error)
                        else -> {}
                    }
                    notice?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                    val idle = scan.state !is ScanViewModel.State.Working
                    Button(::startDocumentScanner, enabled = idle, modifier = Modifier.fillMaxWidth().height(56.dp)) {
                        Icon(Icons.Default.DocumentScanner, null); Spacer(Modifier.width(8.dp)); Text("Scan sheet")
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        OutlinedButton(::startCamera, enabled = idle, modifier = Modifier.weight(1f)) {
                            Icon(Icons.Default.PhotoCamera, null); Spacer(Modifier.width(6.dp)); Text("Camera")
                        }
                        OutlinedButton({ gallery.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                            enabled = idle, modifier = Modifier.weight(1f)) {
                            Icon(Icons.Default.PhotoLibrary, null); Spacer(Modifier.width(6.dp)); Text("Gallery")
                        }
                    }
                }
            }
            Card(onClick = onResults, modifier = Modifier.fillMaxWidth()) {
                Row(Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.GridOn, null, tint = MaterialTheme.colorScheme.primary)
                    Spacer(Modifier.width(16.dp))
                    Column(Modifier.weight(1f)) {
                        Text("Results", style = MaterialTheme.typography.titleMedium)
                        Text("$saved student${if (saved == 1) "" else "s"} saved. Export to Excel.", style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
            Card(onClick = onTemplates, modifier = Modifier.fillMaxWidth()) {
                Row(Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.ViewQuilt, null, tint = MaterialTheme.colorScheme.primary)
                    Spacer(Modifier.width(16.dp))
                    Column(Modifier.weight(1f)) {
                        Text("Sheet layouts and class list", style = MaterialTheme.typography.titleMedium)
                        Text("Registration format, maximum marks, boxes, roster.", style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }
    }
}
