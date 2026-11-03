package com.eduvision.app.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.eduvision.app.EduApp
import com.eduvision.app.data.Xlsx
import com.eduvision.app.recog.Scanner
import com.eduvision.core.model.SheetTemplate
import com.eduvision.core.validate.Roster
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TemplatesScreen(app: EduApp, onBack: () -> Unit, onEdit: (String) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var templates by remember { mutableStateOf(app.templates.all()) }
    var active by remember { mutableStateOf(app.templates.activeId) }
    var roster by remember { mutableStateOf(app.roster.load()) }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var deleting by remember { mutableStateOf<SheetTemplate?>(null) }

    fun refresh() { templates = app.templates.all(); active = app.templates.activeId }

    val samplePicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri: Uri? ->
        uri ?: return@rememberLauncherForActivityResult
        busy = true; message = null
        scope.launch {
            try {
                val photo = withContext(Dispatchers.IO) { Scanner.copyToFile(context, uri) }
                val t = app.scanner.templateFromPhoto(photo, "Sheet layout ${templates.size + 1}")
                app.templates.activeId = t.id
                refresh()
                onEdit(t.id)
            } catch (e: Exception) {
                message = e.message
            }
            busy = false
        }
    }

    val rosterPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        uri ?: return@rememberLauncherForActivityResult
        scope.launch {
            message = try {
                val rows = withContext(Dispatchers.IO) {
                    val type = context.contentResolver.getType(uri).orEmpty()
                    context.contentResolver.openInputStream(uri)!!.use { input ->
                        if (type.contains("csv") || type.startsWith("text")) {
                            input.bufferedReader().readLines().map { line -> line.split(',', ';', '\t').map { it.trim().trim('"') } }
                        } else Xlsx.readFirstSheet(input)
                    }
                }
                val r = Roster.fromRows(rows)
                if (r.isEmpty) "No registration numbers found in that file." else {
                    app.roster.save(r); roster = r
                    "Class list imported: ${r.registrations.size} students."
                }
            } catch (e: Exception) {
                "Could not read that file: ${e.message}"
            }
        }
    }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Sheet layouts") },
            navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
        )
    }) { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Layouts are learned from the first sheet you scan. A photo of another college's sheet " +
                "creates a new layout. Pick a sample photo to set one up by hand.", style = MaterialTheme.typography.bodyMedium)
            if (templates.isEmpty()) Text("No layouts yet.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            templates.forEach { t ->
                Card(Modifier.fillMaxWidth()) {
                    Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        RadioButton(t.id == active, { app.templates.activeId = t.id; refresh() })
                        Column(Modifier.weight(1f)) {
                            Text(t.name, fontWeight = FontWeight.SemiBold)
                            Text(
                                "${t.fields.size} boxes" + (t.registrationMask?.let { " · format $it" } ?: " · format not set") +
                                    " · max ${t.partAMax}/${t.partBMax}",
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                        IconButton({ onEdit(t.id) }) { Icon(Icons.Default.Edit, "Edit ${t.name}") }
                        IconButton({ deleting = t }) { Icon(Icons.Default.Delete, "Delete ${t.name}") }
                    }
                }
            }
            OutlinedButton({ samplePicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                enabled = !busy, modifier = Modifier.fillMaxWidth()) {
                if (busy) { CircularProgressIndicator(Modifier.width(18.dp), strokeWidth = 2.dp); Spacer(Modifier.width(8.dp)) }
                Text("New layout from a sample photo")
            }

            Spacer(Modifier.width(8.dp))
            Text("Class list", style = MaterialTheme.typography.titleMedium)
            Text(
                if (roster.isEmpty) "No class list. Importing one (.xlsx or .csv with a registration column) lets the app catch misread numbers and settle 0/D-style doubts."
                else "${roster.registrations.size} registration numbers. Readings not on the list go to review.",
                style = MaterialTheme.typography.bodyMedium,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button({ rosterPicker.launch(arrayOf("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "text/*")) }) {
                    Text(if (roster.isEmpty) "Import class list" else "Replace")
                }
                if (!roster.isEmpty) OutlinedButton({ app.roster.clear(); roster = Roster.EMPTY }) { Text("Remove") }
            }
            message?.let { Text(it, color = MaterialTheme.colorScheme.primary) }
            Text("${app.corrections.count()} checked fields kept on this phone as labelled samples for improving the reader.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }

    deleting?.let { t ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("Delete \"${t.name}\"?") },
            text = { Text("Saved results stay. The next sheet of this layout will be learned again.") },
            confirmButton = { TextButton({ app.templates.delete(t.id); deleting = null; refresh() }) { Text("Delete") } },
            dismissButton = { TextButton({ deleting = null }) { Text("Cancel") } },
        )
    }
}
