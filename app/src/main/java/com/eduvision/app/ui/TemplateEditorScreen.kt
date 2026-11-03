package com.eduvision.app.ui

import android.graphics.BitmapFactory
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.eduvision.app.EduApp
import com.eduvision.core.model.FieldKind
import com.eduvision.core.model.NormBox
import com.eduvision.core.model.TemplateField
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

private val kindColors = mapOf(
    FieldKind.REGISTRATION to Color(0xFF1E88E5),
    FieldKind.PART_A to Color(0xFF43A047),
    FieldKind.PART_B to Color(0xFF8E24AA),
    FieldKind.WRITTEN_TOTAL to Color(0xFFF4511E),
    FieldKind.QUESTION to Color(0xFF00897B),
    FieldKind.MARK to Color(0xFFD81B60),
    FieldKind.TEXT to Color(0xFF6D4C41),
)

/** Names shown to teachers for each kind of field. */
private val kindNames = mapOf(
    FieldKind.REGISTRATION to "Registration / roll no.",
    FieldKind.PART_A to "Part-A total",
    FieldKind.PART_B to "Part-B total",
    FieldKind.WRITTEN_TOTAL to "Grand total (check)",
    FieldKind.QUESTION to "Question mark",
    FieldKind.MARK to "Other number",
    FieldKind.TEXT to "Other text",
)

/** A field being added or edited: the box, and the row of boxes it belongs to, if any. */
private data class Draft(val index: Int?, val box: NormBox, val row: NormBox?, val rowCells: Int, val field: TemplateField?)

/**
 * A paper layout's fields, set up on its sample sheet. The teacher taps a
 * printed box and says what it is; the box snaps to the printed border, and
 * a row of character boxes can be read as one value. "Draw" is for writing
 * on a line with no box. Every later scan of this layout reads these fields.
 */
@OptIn(ExperimentalMaterial3Api::class, androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
fun TemplateEditorScreen(app: EduApp, id: String, setup: Boolean = false, onBack: () -> Unit, onSaved: () -> Unit = onBack) {
    val original = remember { app.templates.get(id) }
    if (original == null) { onBack(); return }
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf(original.name) }
    var mask by remember { mutableStateOf(original.registrationMask.orEmpty()) }
    var aMax by remember { mutableStateOf(original.partAMax.toString()) }
    var bMax by remember { mutableStateOf(original.partBMax.toString()) }
    var fields by remember { mutableStateOf(original.fields) }
    var drawMode by remember { mutableStateOf(false) }
    var drag by remember { mutableStateOf<Pair<Offset, Offset>?>(null) }
    var draft by remember { mutableStateOf<Draft?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    val image = remember {
        app.templates.referenceFile(original)?.takeIf { it.exists() }?.let { BitmapFactory.decodeFile(it.path) }
    }

    fun save() {
        if (setup && fields.none { it.kind == FieldKind.REGISTRATION }) {
            message = "Tap the registration / roll number box first: results are saved per student."
            return
        }
        app.templates.save(original.copy(
            name = name.ifBlank { original.name },
            registrationMask = mask.ifBlank { null },
            partAMax = aMax.toIntOrNull() ?: original.partAMax,
            partBMax = bMax.toIntOrNull() ?: original.partBMax,
            fields = fields,
            auto = original.auto && fields == original.fields,
        ))
        onSaved()
    }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text(if (setup) "New paper layout" else "Edit layout") },
            navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back without saving") } },
            actions = { Button(::save, Modifier.padding(end = 8.dp)) { Text(if (setup) "Save and read" else "Save") } },
        )
    }) { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
                Text(
                    (if (setup) "This paper is new to the app. " else "") +
                        "Tap each box you want read: the registration or roll number, the totals, any other marks. " +
                        "Boxes the app recognised are already marked; tap one to change or remove it. " +
                        "Every later sheet of this layout is read automatically.",
                    Modifier.padding(12.dp), style = MaterialTheme.typography.bodyMedium,
                )
            }
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                SegmentedButton(!drawMode, { drawMode = false }, SegmentedButtonDefaults.itemShape(0, 2)) { Text("Tap a box") }
                SegmentedButton(drawMode, { drawMode = true }, SegmentedButtonDefaults.itemShape(1, 2)) { Text("Draw a box") }
            }
            message?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            if (image == null) {
                Text("This layout has no sample image.", color = MaterialTheme.colorScheme.error)
            } else {
                val bmp = remember(image) { image.asImageBitmap() }
                Box(Modifier.fillMaxWidth().aspectRatio(image.width.toFloat() / image.height)) {
                    Image(bmp, contentDescription = "Sample sheet", Modifier.fillMaxSize(), contentScale = ContentScale.FillBounds)
                    Canvas(
                        Modifier.fillMaxSize()
                            .pointerInput(drawMode) {
                                if (!drawMode) return@pointerInput
                                detectDragGestures(
                                    onDragStart = { drag = it to it },
                                    onDrag = { change, _ -> drag = drag?.copy(second = change.position) },
                                    onDragEnd = {
                                        val (a, b) = drag ?: return@detectDragGestures
                                        drag = null
                                        val w = size.width.toFloat(); val h = size.height.toFloat()
                                        val box = NormBox((min(a.x, b.x) / w).toDouble(), (min(a.y, b.y) / h).toDouble(),
                                            (max(a.x, b.x) / w).toDouble(), (max(a.y, b.y) / h).toDouble())
                                        if (box.width > 0.01 && box.height > 0.005) draft = Draft(null, box, null, 1, null)
                                    },
                                )
                            }
                            .pointerInput(fields, drawMode) {
                                if (drawMode) return@pointerInput
                                detectTapGestures { p ->
                                    val nx = (p.x / size.width).toDouble()
                                    val ny = (p.y / size.height).toDouble()
                                    val hit = fields.indexOfLast { f -> nx in f.box.left..f.box.right && ny in f.box.top..f.box.bottom }
                                    if (hit >= 0) {
                                        draft = Draft(hit, fields[hit].box, null, fields[hit].cells, fields[hit])
                                        return@detectTapGestures
                                    }
                                    message = null
                                    scope.launch {
                                        val picked = app.scanner.boxAt(original, nx * image.width, ny * image.height)
                                        if (picked == null) {
                                            message = "No printed box there. Switch to \"Draw a box\" for writing on a line."
                                        } else {
                                            fun norm(b: com.eduvision.core.recog.Box) =
                                                NormBox(b.x0 / image.width, b.y0 / image.height, b.x1 / image.width, b.y1 / image.height)
                                            draft = Draft(null, norm(picked.cell), picked.row?.let(::norm), picked.rowCells, null)
                                        }
                                    }
                                }
                            },
                    ) {
                        fields.forEach { f ->
                            val c = kindColors[f.kind] ?: Color.Red
                            drawRect(c.copy(alpha = 0.18f), Offset((f.box.left * size.width).toFloat(), (f.box.top * size.height).toFloat()),
                                Size((f.box.width * size.width).toFloat(), (f.box.height * size.height).toFloat()))
                            drawRect(c, Offset((f.box.left * size.width).toFloat(), (f.box.top * size.height).toFloat()),
                                Size((f.box.width * size.width).toFloat(), (f.box.height * size.height).toFloat()), style = Stroke(4f))
                        }
                        drag?.let { (a, b) ->
                            drawRect(Color.Red, Offset(min(a.x, b.x), min(a.y, b.y)), Size(abs(a.x - b.x), abs(a.y - b.y)), style = Stroke(3f))
                        }
                    }
                }
            }
            Text("Fields (${fields.size})", style = MaterialTheme.typography.titleMedium)
            if (fields.isEmpty()) Text("None yet. Tap a box on the sheet above.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                fields.forEachIndexed { i, f ->
                    AssistChip({ draft = Draft(i, f.box, null, f.cells, f) },
                        label = { Text(f.title + if (f.cells > 1) " (${f.cells} boxes)" else "") })
                }
            }
            Text("Layout", style = MaterialTheme.typography.titleMedium)
            OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            if (fields.any { it.kind == FieldKind.REGISTRATION }) {
                OutlinedTextField(mask, { mask = it.uppercase().filter { c -> c in "DAX" } }, singleLine = true,
                    label = { Text("Registration format (D digit, A letter, X either), optional") }, modifier = Modifier.fillMaxWidth(),
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters))
            }
            if (fields.any { it.kind == FieldKind.PART_A || it.kind == FieldKind.PART_B }) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(aMax, { aMax = it.filter(Char::isDigit) }, label = { Text("Part-A max") }, singleLine = true,
                        modifier = Modifier.weight(1f), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                    OutlinedTextField(bMax, { bMax = it.filter(Char::isDigit) }, label = { Text("Part-B max") }, singleLine = true,
                        modifier = Modifier.weight(1f), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                }
            }
        }
    }

    draft?.let { d ->
        FieldDialog(d, fields,
            onDismiss = { draft = null },
            onDelete = { fields = fields.filterIndexed { j, _ -> j != d.index }; draft = null },
            onSave = { f ->
                fields = if (d.index != null) fields.toMutableList().also { it[d.index] = f }
                // One registration / Part-A / Part-B / grand total per layout.
                else (if (f.kind in setOf(FieldKind.QUESTION, FieldKind.MARK, FieldKind.TEXT)) fields else fields.filter { it.kind != f.kind }) + f
                draft = null
            })
    }
}

@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
private fun FieldDialog(d: Draft, fields: List<TemplateField>, onDismiss: () -> Unit, onDelete: () -> Unit, onSave: (TemplateField) -> Unit) {
    val taken = fields.map { it.kind }.toSet()
    var kind by remember {
        mutableStateOf(d.field?.kind ?: when {
            FieldKind.REGISTRATION !in taken && d.rowCells >= 4 -> FieldKind.REGISTRATION
            FieldKind.REGISTRATION !in taken -> FieldKind.REGISTRATION
            FieldKind.PART_A !in taken -> FieldKind.PART_A
            FieldKind.PART_B !in taken -> FieldKind.PART_B
            else -> FieldKind.MARK
        })
    }
    var label by remember { mutableStateOf(d.field?.label.orEmpty()) }
    var max by remember { mutableStateOf(d.field?.maxMarks?.toString().orEmpty()) }
    var wholeRow by remember { mutableStateOf(d.field == null && d.row != null && d.rowCells >= 4) }
    val named = kind == FieldKind.QUESTION || kind == FieldKind.MARK || kind == FieldKind.TEXT
    val number = kind != FieldKind.REGISTRATION && kind != FieldKind.TEXT

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (d.field == null) "What is in this box?" else "Edit field") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    FieldKind.entries.forEach { k ->
                        FilterChip(kind == k, { kind = k }, label = { Text(kindNames[k] ?: k.label) })
                    }
                }
                if (named) {
                    OutlinedTextField(label, { label = it }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                        label = { Text(if (kind == FieldKind.QUESTION) "Question (e.g. Q3)" else "Column name (e.g. Internal marks)") })
                }
                if (number && kind != FieldKind.PART_A && kind != FieldKind.PART_B && kind != FieldKind.WRITTEN_TOTAL) {
                    OutlinedTextField(max, { max = it.filter(Char::isDigit) }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                        label = { Text("Maximum marks (optional)") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                }
                if (d.row != null && d.rowCells >= 2) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Read the whole row of ${d.rowCells} boxes as one value (one character per box)", Modifier.weight(1f),
                            style = MaterialTheme.typography.bodySmall)
                        Switch(wholeRow, { wholeRow = it })
                    }
                }
                if (d.field?.cells?.let { it > 1 } == true) {
                    Text("Read as ${d.field.cells} separate boxes.", style = MaterialTheme.typography.bodySmall)
                }
            }
        },
        confirmButton = {
            TextButton({
                val useRow = wholeRow && d.row != null
                onSave(TemplateField(
                    kind = kind,
                    box = if (useRow) d.row!! else d.box,
                    label = if (named) label.trim().ifEmpty { if (kind == FieldKind.QUESTION) "Q${fields.count { it.kind == kind } + 1}" else kindNames[kind]!! } else "",
                    part = d.field?.part ?: "A",
                    maxMarks = max.toIntOrNull(),
                    cells = if (useRow) d.rowCells else d.field?.cells ?: 0,
                ))
            }, enabled = !named || kind == FieldKind.QUESTION || label.isNotBlank()) { Text("Save") }
        },
        dismissButton = {
            Row {
                if (d.field != null) TextButton(onDelete) { Text("Remove", color = MaterialTheme.colorScheme.error) }
                TextButton(onDismiss) { Text("Cancel") }
            }
        },
    )
}
