package com.eduvision.app.ui

import android.graphics.BitmapFactory
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
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
import kotlin.math.max
import kotlin.math.min

private val kindColors = mapOf(
    FieldKind.REGISTRATION to Color(0xFF1E88E5),
    FieldKind.PART_A to Color(0xFF43A047),
    FieldKind.PART_B to Color(0xFF8E24AA),
    FieldKind.WRITTEN_TOTAL to Color(0xFFF4511E),
    FieldKind.QUESTION to Color(0xFF00897B),
)

/**
 * Template settings and boxes. Pick a field type, then drag a rectangle over
 * the box on the sample sheet; tap a box to select it. Boxes only need to be
 * roughly right: each scan snaps them to the printed cell.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TemplateEditorScreen(app: EduApp, id: String, onBack: () -> Unit) {
    val original = remember { app.templates.get(id) }
    if (original == null) { onBack(); return }
    var name by remember { mutableStateOf(original.name) }
    var mask by remember { mutableStateOf(original.registrationMask.orEmpty()) }
    var aMax by remember { mutableStateOf(original.partAMax.toString()) }
    var bMax by remember { mutableStateOf(original.partBMax.toString()) }
    var fields by remember { mutableStateOf(original.fields) }
    var kind by remember { mutableStateOf(FieldKind.REGISTRATION) }
    var selected by remember { mutableStateOf<Int?>(null) }
    var drag by remember { mutableStateOf<Pair<Offset, Offset>?>(null) }
    val image = remember {
        app.templates.referenceFile(original)?.takeIf { it.exists() }?.let { BitmapFactory.decodeFile(it.path) }
    }

    fun save() {
        app.templates.save(original.copy(
            name = name.ifBlank { original.name },
            registrationMask = mask.ifBlank { null },
            partAMax = aMax.toIntOrNull() ?: original.partAMax,
            partBMax = bMax.toIntOrNull() ?: original.partBMax,
            fields = fields,
            auto = original.auto && fields == original.fields,
        ))
        onBack()
    }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Edit layout") },
            navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back without saving") } },
            actions = { Button(::save, Modifier.padding(end = 8.dp)) { Text("Save") } },
        )
    }) { pad ->
        Column(
            Modifier.fillMaxSize().padding(pad).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(mask, { mask = it.uppercase().filter { c -> c in "DAX" } }, singleLine = true,
                label = { Text("Registration format (D digit, A letter, X either)") }, modifier = Modifier.fillMaxWidth(),
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(aMax, { aMax = it.filter(Char::isDigit) }, label = { Text("Part-A max") }, singleLine = true,
                    modifier = Modifier.weight(1f), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                OutlinedTextField(bMax, { bMax = it.filter(Char::isDigit) }, label = { Text("Part-B max") }, singleLine = true,
                    modifier = Modifier.weight(1f), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
            }
            Text("Draw boxes", style = MaterialTheme.typography.titleMedium)
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                FieldKind.entries.forEach { k ->
                    FilterChip(kind == k, { kind = k }, label = { Text(k.label) })
                }
            }
            if (image == null) {
                Text("This layout has no sample image.", color = MaterialTheme.colorScheme.error)
            } else {
                val bmp = remember(image) { image.asImageBitmap() }
                Box(Modifier.fillMaxWidth().aspectRatio(image.width.toFloat() / image.height)) {
                    Image(bmp, contentDescription = "Sample sheet", Modifier.fillMaxSize(), contentScale = ContentScale.FillBounds)
                    Canvas(
                        Modifier.fillMaxSize()
                            .pointerInput(kind) {
                                detectDragGestures(
                                    onDragStart = { drag = it to it },
                                    onDrag = { change, _ -> drag = drag?.copy(second = change.position) },
                                    onDragEnd = {
                                        val (a, b) = drag ?: return@detectDragGestures
                                        drag = null
                                        val w = size.width.toFloat(); val h = size.height.toFloat()
                                        val box = NormBox(
                                            (min(a.x, b.x) / w).toDouble(), (min(a.y, b.y) / h).toDouble(),
                                            (max(a.x, b.x) / w).toDouble(), (max(a.y, b.y) / h).toDouble(),
                                        )
                                        if (box.width < 0.01 || box.height < 0.005) return@detectDragGestures
                                        val qn = fields.count { it.kind == FieldKind.QUESTION } + 1
                                        val f = TemplateField(kind, box, label = if (kind == FieldKind.QUESTION) "Q$qn" else "",
                                            part = if (kind == FieldKind.QUESTION && qn > 10) "B" else "A")
                                        // One box per kind, except questions.
                                        fields = (if (kind == FieldKind.QUESTION) fields else fields.filter { it.kind != kind }) + f
                                        selected = fields.lastIndex
                                    },
                                )
                            }
                            .pointerInput(fields) {
                                detectTapGestures { p ->
                                    val w = size.width.toFloat(); val h = size.height.toFloat()
                                    selected = fields.indexOfLast { f ->
                                        p.x / w in f.box.left..f.box.right && p.y / h in f.box.top..f.box.bottom
                                    }.takeIf { it >= 0 }
                                }
                            },
                    ) {
                        fields.forEachIndexed { i, f ->
                            val c = kindColors[f.kind] ?: Color.Red
                            drawRect(c, Offset((f.box.left * size.width).toFloat(), (f.box.top * size.height).toFloat()),
                                Size((f.box.width * size.width).toFloat(), (f.box.height * size.height).toFloat()),
                                style = Stroke(if (i == selected) 6f else 3f))
                        }
                        drag?.let { (a, b) ->
                            drawRect(kindColors[kind]!!, Offset(min(a.x, b.x), min(a.y, b.y)),
                                Size(kotlin.math.abs(a.x - b.x), kotlin.math.abs(a.y - b.y)), style = Stroke(3f))
                        }
                    }
                }
            }
            selected?.let { i ->
                fields.getOrNull(i)?.let { f ->
                    Row {
                        Text("Selected: ${f.title}", Modifier.weight(1f))
                        OutlinedButton({ fields = fields.filterIndexed { j, _ -> j != i }; selected = null }) { Text("Delete box") }
                    }
                }
            }
            Spacer(Modifier.width(4.dp))
            Text("Boxes: " + fields.joinToString { it.title }.ifEmpty { "none" }, style = MaterialTheme.typography.bodySmall)
        }
    }
}
