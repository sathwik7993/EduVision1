package com.eduvision.app.ui

import android.content.ActivityNotFoundException
import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import com.eduvision.app.EduApp

private const val XLSX = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ResultsScreen(app: EduApp, onBack: () -> Unit) {
    val context = LocalContext.current
    var rows by remember { mutableStateOf(app.results.all().sortedBy { it.registrationNo }) }
    var menu by remember { mutableStateOf(false) }
    var confirmClear by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }

    fun uri() = FileProvider.getUriForFile(context, "${context.packageName}.files", app.results.exportXlsx())

    fun share() {
        val send = Intent(Intent.ACTION_SEND).setType(XLSX).putExtra(Intent.EXTRA_STREAM, uri())
            .putExtra(Intent.EXTRA_SUBJECT, "Exam results").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        context.startActivity(Intent.createChooser(send, "Send results"))
    }

    fun open() {
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri(), XLSX).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
        } catch (_: ActivityNotFoundException) {
            message = "No spreadsheet app installed. Use Share to send the file instead."
        }
    }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Results (${rows.size})") },
            navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            actions = {
                IconButton(::share, enabled = rows.isNotEmpty()) { Icon(Icons.Default.Share, "Share workbook") }
                IconButton({ menu = true }) { Icon(Icons.Default.MoreVert, "More") }
                DropdownMenu(menu, { menu = false }) {
                    DropdownMenuItem({ Text("Delete all results") }, { menu = false; confirmClear = true }, enabled = rows.isNotEmpty())
                }
            },
        )
    }) { pad ->
        Column(Modifier.fillMaxSize().padding(pad).padding(horizontal = 16.dp)) {
            if (rows.isEmpty()) {
                Text("Nothing saved yet. Scan a sheet and save it to see it here.", Modifier.padding(vertical = 24.dp))
                return@Column
            }
            Row(Modifier.padding(vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(::open, Modifier.weight(1f)) { Text("Open in Excel") }
                OutlinedButton(::share, Modifier.weight(1f)) { Text("Share .xlsx") }
            }
            message?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            Row(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                Text("Registration", Modifier.weight(2f), fontWeight = FontWeight.SemiBold)
                Text("A", Modifier.weight(0.6f), fontWeight = FontWeight.SemiBold)
                Text("B", Modifier.weight(0.6f), fontWeight = FontWeight.SemiBold)
                Text("Total", Modifier.weight(0.8f), fontWeight = FontWeight.SemiBold)
                Text("", Modifier.weight(0.6f))
            }
            HorizontalDivider()
            LazyColumn {
                items(rows, key = { it.registrationNo }) { row ->
                    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(row.registrationNo, Modifier.weight(2f), fontFamily = FontFamily.Monospace)
                        Text("${row.partA}", Modifier.weight(0.6f))
                        Text("${row.partB}", Modifier.weight(0.6f))
                        Text("${row.total}", Modifier.weight(0.8f), fontWeight = FontWeight.Bold)
                        IconButton({ app.results.delete(row.registrationNo); rows = app.results.all().sortedBy { it.registrationNo } }, Modifier.weight(0.6f)) {
                            Icon(Icons.Default.Delete, "Delete ${row.registrationNo}")
                        }
                    }
                    HorizontalDivider()
                }
            }
        }
    }

    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text("Delete all results?") },
            text = { Text("This removes all ${rows.size} saved students from this phone. Share the workbook first if you need it.") },
            confirmButton = { TextButton({ app.results.clear(); rows = emptyList(); confirmClear = false }) { Text("Delete") } },
            dismissButton = { TextButton({ confirmClear = false }) { Text("Cancel") } },
        )
    }
}
