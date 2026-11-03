package com.eduvision.app.ui

import android.graphics.BitmapFactory
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.eduvision.app.EduApp
import com.eduvision.app.recog.Scanner
import com.eduvision.core.model.ExtractedField
import com.eduvision.core.model.LabelledMark
import com.eduvision.core.model.ScanResult

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReviewScreen(app: EduApp, scan: ScanViewModel, onDone: () -> Unit) {
    val state = scan.state
    var confirmOverwrite by remember { mutableStateOf(false) }
    var showDetails by remember { mutableStateOf(false) }

    fun leave() { scan.reset(); onDone() }
    BackHandler { leave() }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Check before saving") },
            navigationIcon = { IconButton(::leave) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Discard") } },
        )
    }) { pad ->
        if (state !is ScanViewModel.State.Ready) {
            Column(Modifier.padding(pad).padding(24.dp)) {
                when (state) {
                    is ScanViewModel.State.Failed -> Text(state.message, color = MaterialTheme.colorScheme.error)
                    else -> Text("Reading the sheet...")
                }
            }
            return@Scaffold
        }
        val r = state.result
        val t = state.scan.template
        Column(
            Modifier.fillMaxSize().padding(pad).imePadding().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (state.scan.newLayout || t.registrationMask == null) {
                NewLayoutCard(t.name, state.scan.newLayout, r.registrationNo.value, t.partAMax, t.partBMax,
                    onMask = scan::setRegistrationMask, onMaxima = scan::setMaxima)
            }

            FieldCard("Registration No", r.registrationNo, text = true, testTag = "reg") { v ->
                scan.edit { it.copy(registrationNo = v) }
            }
            FieldCard("Part-A total (max ${t.partAMax})", r.partA, testTag = "partA") { v -> scan.edit { it.copy(partA = v) } }
            FieldCard("Part-B total (max ${t.partBMax})", r.partB, testTag = "partB") { v -> scan.edit { it.copy(partB = v) } }
            r.writtenTotals.forEachIndexed { i, m ->
                MarkCard(m) { v -> scan.edit { res -> res.copy(writtenTotals = res.writtenTotals.toMutableList().also { it[i] = it[i].copy(field = v) }) } }
            }
            r.questions.forEachIndexed { i, m ->
                MarkCard(m) { v -> scan.edit { res -> res.copy(questions = res.questions.toMutableList().also { it[i] = it[i].copy(field = v) }) } }
            }

            Card(Modifier.fillMaxWidth()) {
                Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Total (Part-A + Part-B)", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
                    Text("${r.total}", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                }
            }

            val blocking = scan.blockingErrors()
            blocking.forEach { Text(it, color = MaterialTheme.colorScheme.error) }
            if (!r.isReadyToSave) {
                Text("Check: ${r.fieldsNeedingReview.joinToString()}. Correct a value or tap \"Matches the sheet\".",
                    color = Warn, style = MaterialTheme.typography.bodyMedium)
            }
            Button(
                { if (scan.isDuplicate()) confirmOverwrite = true else { scan.save(); onDone() } },
                enabled = r.isReadyToSave && blocking.isEmpty(),
                modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp).testTag("save"),
            ) { Text("Save to results") }

            TextButton({ showDetails = !showDetails }) { Text(if (showDetails) "Hide details" else "What the scanner read") }
            if (showDetails) Details(r, t.name)
        }
    }

    if (confirmOverwrite) {
        val reg = (state as? ScanViewModel.State.Ready)?.result?.registrationNo?.value.orEmpty()
        AlertDialog(
            onDismissRequest = { confirmOverwrite = false },
            title = { Text("Already saved") },
            text = { Text("$reg is already in the results. Replace its marks with this sheet?") },
            confirmButton = { TextButton({ confirmOverwrite = false; scan.save(); onDone() }) { Text("Replace") } },
            dismissButton = { TextButton({ confirmOverwrite = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun NewLayoutCard(name: String, isNew: Boolean, reading: String, aMax: Int, bMax: Int, onMask: (String) -> Unit, onMaxima: (Int, Int) -> Unit) {
    var mask by remember(reading) { mutableStateOf(Scanner.guessMask(reading)) }
    var a by remember { mutableStateOf(aMax.toString()) }
    var b by remember { mutableStateOf(bMax.toString()) }
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(if (isNew) "New sheet layout learned: $name" else "Set up \"$name\"", fontWeight = FontWeight.SemiBold)
            Text("Registration format, one letter per box: D digit, A letter, X either (e.g. DDADDADDXX for 23H51A66K1). " +
                "It lets the reader tell 0 from O and 5 from S.", style = MaterialTheme.typography.bodySmall)
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(mask, { mask = it.uppercase().filter { c -> c in "DAX" } }, label = { Text("Format") },
                    singleLine = true, modifier = Modifier.weight(1f),
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters))
                Spacer(Modifier.width(8.dp))
                Button({ onMask(mask) }, enabled = mask.length >= 4) { Text("Apply") }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(a, { a = it.filter(Char::isDigit) }, label = { Text("Part-A max") }, singleLine = true,
                    modifier = Modifier.weight(1f), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                Spacer(Modifier.width(8.dp))
                OutlinedTextField(b, { b = it.filter(Char::isDigit) }, label = { Text("Part-B max") }, singleLine = true,
                    modifier = Modifier.weight(1f), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                Spacer(Modifier.width(8.dp))
                OutlinedButton({ onMaxima(a.toIntOrNull() ?: aMax, b.toIntOrNull() ?: bMax) }) { Text("Set") }
            }
        }
    }
}

@Composable
private fun MarkCard(m: LabelledMark, onChange: (ExtractedField) -> Unit) =
    FieldCard(m.label + (m.maxMarks?.let { " (max $it)" } ?: ""), m.field, blankOk = true, onChange = onChange)

/**
 * One field: the exact pixels the model read, its value (editable), and
 * why it needs checking. Typing a value or tapping "Matches the sheet"
 * makes it the teacher's value.
 */
@Composable
fun FieldCard(
    title: String,
    field: ExtractedField,
    text: Boolean = false,
    blankOk: Boolean = false,
    testTag: String = title,
    onChange: (ExtractedField) -> Unit,
) {
    val needs = if (blankOk) !field.edited && (field.issue != null || field.confidence < ExtractedField.TRUSTED_ABOVE) else field.needsReview
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(if (needs) Icons.Default.Warning else Icons.Default.CheckCircle, null, tint = if (needs) Warn else Good)
                Spacer(Modifier.width(8.dp))
                Text(title, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                Text(
                    when {
                        field.edited -> "confirmed"
                        else -> "${(field.confidence * 100).toInt()}% sure"
                    },
                    style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            field.crop?.let { png ->
                val bmp = remember(png) { BitmapFactory.decodeByteArray(png, 0, png.size)?.asImageBitmap() }
                bmp?.let {
                    Image(it, contentDescription = "What the scanner read for $title",
                        Modifier.fillMaxWidth().heightIn(max = 72.dp).background(Color.White, RoundedCornerShape(6.dp)),
                        contentScale = ContentScale.Fit)
                }
            }
            OutlinedTextField(
                field.value,
                { v -> onChange(ExtractedField.manual(if (text) v.uppercase().filter { it.isLetterOrDigit() } else v.filter(Char::isDigit), field.crop)) },
                singleLine = true,
                textStyle = MaterialTheme.typography.titleLarge.copy(fontFamily = FontFamily.Monospace),
                modifier = Modifier.fillMaxWidth().testTag(testTag),
                keyboardOptions = KeyboardOptions(
                    keyboardType = if (text) KeyboardType.Ascii else KeyboardType.Number,
                    capitalization = KeyboardCapitalization.Characters,
                ),
                placeholder = { Text(if (blankOk) "blank" else "") },
            )
            if (!field.edited) {
                field.issue?.let { Text(it, color = Warn, style = MaterialTheme.typography.bodySmall) }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    field.suggestion?.let { s ->
                        AssistChip({ onChange(ExtractedField.manual(s, field.crop)) }, label = { Text("Use $s") })
                    }
                    if (needs && (field.value.isNotEmpty() || blankOk)) {
                        AssistChip({ onChange(ExtractedField.manual(field.value, field.crop)) }, label = { Text("Matches the sheet") })
                    }
                }
            }
        }
    }
}

@Composable
private fun Details(r: ScanResult, template: String) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("Layout: $template", style = MaterialTheme.typography.bodySmall)
            Text("Time (ms): " + r.timingsMs.filterKeys { it != "inliers" }.entries.joinToString { "${it.key} ${it.value}" },
                style = MaterialTheme.typography.bodySmall)
            Text("Feature matches: ${r.timingsMs["inliers"] ?: "-"}", style = MaterialTheme.typography.bodySmall)
            HorizontalDivider()
            r.diagnostics.forEach { (k, v) -> Text("$k: $v", style = MaterialTheme.typography.bodySmall) }
            listOf("Registration" to r.registrationNo, "Part-A" to r.partA, "Part-B" to r.partB).forEach { (k, f) ->
                Text("$k read \"${f.rawText ?: f.value}\" at ${"%.2f".format(f.confidence)}", style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}
