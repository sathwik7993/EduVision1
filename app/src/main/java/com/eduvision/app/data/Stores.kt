package com.eduvision.app.data

import android.content.Context
import com.eduvision.core.model.FieldKind
import com.eduvision.core.model.ScanResult
import com.eduvision.core.model.SheetTemplate
import com.eduvision.core.validate.Roster
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import org.opencv.core.Mat
import org.opencv.imgcodecs.Imgcodecs
import java.io.File
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

/** Writes through a temp file so a crash never leaves half a file behind. */
internal fun File.writeAtomically(text: String) {
    val tmp = File(parentFile, "$name.tmp")
    tmp.writeText(text)
    if (!tmp.renameTo(this)) { delete(); tmp.renameTo(this) }
}

/** Sheet layouts: one JSON file each plus its grayscale reference image. */
class TemplateStore(context: Context) {
    private val dir = File(context.filesDir, "templates").apply { mkdirs() }
    private val prefs = context.getSharedPreferences("templates", Context.MODE_PRIVATE)
    private val references = HashMap<String, Mat>()

    fun all(): List<SheetTemplate> = dir.listFiles { f -> f.extension == "json" }.orEmpty()
        .mapNotNull { runCatching { SheetTemplate.fromJson(it.readText()) }.getOrNull() }
        .sortedBy { it.name.lowercase() }

    fun get(id: String) = File(dir, "$id.json").takeIf { it.exists() }?.let { SheetTemplate.fromJson(it.readText()) }

    var activeId: String?
        get() = prefs.getString("active", null)?.takeIf { File(dir, "$it.json").exists() }
        set(v) { prefs.edit().putString("active", v).apply() }

    fun active() = activeId?.let(::get)

    fun save(t: SheetTemplate, reference: Mat? = null) {
        if (reference != null) {
            Imgcodecs.imwrite(File(dir, "${t.id}_ref.png").path, reference)
            references[t.id] = reference
        }
        File(dir, "${t.id}.json").writeAtomically(t.copy(referenceImage = "${t.id}_ref.png").toJson())
    }

    fun reference(t: SheetTemplate): Mat? = references.getOrPut(t.id) {
        val f = File(dir, t.referenceImage ?: return null)
        if (!f.exists()) return null
        Imgcodecs.imread(f.path, Imgcodecs.IMREAD_GRAYSCALE)
    }

    fun referenceFile(t: SheetTemplate) = t.referenceImage?.let { File(dir, it) }

    fun delete(id: String) {
        File(dir, "$id.json").delete()
        File(dir, "${id}_ref.png").delete()
        references.remove(id)
        if (activeId == id) activeId = all().firstOrNull()?.id
    }

    fun newId() = "t" + System.currentTimeMillis().toString(36)
}

@Serializable
data class ResultRow(
    val registrationNo: String,
    val partA: Int,
    val partB: Int,
    val total: Int,
    val scannedAt: String,
    val template: String = "",
)

/**
 * Saved marks. The JSON file is the record; the workbook is generated from it
 * on export, so it always has the right columns and can never be corrupted
 * by a half-written save.
 */
class ResultsStore(context: Context) {
    private val file = File(context.filesDir, "results.json")
    private val exportDir = File(context.cacheDir, "exports").apply { mkdirs() }
    private val serializer = ListSerializer(ResultRow.serializer())

    fun all(): List<ResultRow> = if (!file.exists()) emptyList()
    else runCatching { json.decodeFromString(serializer, file.readText()) }.getOrDefault(emptyList())

    fun registrations() = all().map { it.registrationNo.uppercase() }.toSet()

    fun contains(reg: String) = reg.trim().uppercase() in registrations()

    /** Inserts, or replaces the row with the same registration number. */
    fun save(result: ScanResult, templateName: String) {
        val reg = result.registrationNo.value.trim().uppercase()
        val row = ResultRow(reg, result.partAValue, result.partBValue, result.total,
            LocalDateTime.now().format(DateTimeFormatter.ISO_LOCAL_DATE_TIME).take(19), templateName)
        write(all().filter { it.registrationNo != reg } + row)
    }

    fun delete(reg: String) = write(all().filter { it.registrationNo != reg })

    fun clear() { file.delete() }

    private fun write(rows: List<ResultRow>) = file.writeAtomically(json.encodeToString(serializer, rows))

    /** Marks are numbers, not text, so Excel can SUM and AVERAGE them. */
    fun exportXlsx(): File {
        val out = File(exportDir, "exam_results.xlsx")
        val rows = listOf(listOf("Registration No", "Part-A", "Part-B", "Total", "Scanned At", "Layout").map { Xlsx.Text(it) }) +
            all().sortedBy { it.registrationNo }.map {
                listOf(Xlsx.Text(it.registrationNo), Xlsx.Num(it.partA), Xlsx.Num(it.partB), Xlsx.Num(it.total),
                    Xlsx.Text(it.scannedAt.replace('T', ' ')), Xlsx.Text(it.template))
            }
        out.outputStream().use { Xlsx.write(it, "Results", rows) }
        return out
    }
}

/** The class list used to check registration numbers. Never leaves the device. */
class RosterStore(context: Context) {
    private val file = File(context.filesDir, "class_roster.json")
    private val serializer = ListSerializer(String.serializer())

    fun load(): Roster = if (!file.exists()) Roster.EMPTY
    else runCatching { Roster(json.decodeFromString(serializer, file.readText())) }.getOrDefault(Roster.EMPTY)

    fun save(r: Roster) = file.writeAtomically(json.encodeToString(serializer, r.registrations.sorted()))

    fun clear() { file.delete() }
}

@Serializable
private data class CorrectionEntry(
    val file: String,
    val field: String,
    val value: String,
    val modelValue: String,
    val confidence: Double,
    val edited: Boolean,
    val savedAt: String,
)

/**
 * Every confirmed field is kept as a labelled crop (PNG + JSONL index): the
 * real handwriting needed to measure and retrain the model. Local only.
 */
class CorrectionStore(context: Context) {
    val dir = File(context.filesDir, "labelled_crops").apply { mkdirs() }

    fun record(result: ScanResult, modelValues: Map<FieldKind, String>) {
        val now = LocalDateTime.now().format(DateTimeFormatter.ISO_LOCAL_DATE_TIME).take(19)
        val index = File(dir, "index.jsonl")
        val stamp = System.currentTimeMillis()
        listOf(
            Triple(FieldKind.REGISTRATION, result.registrationNo, "registration"),
            Triple(FieldKind.PART_A, result.partA, "partA"),
            Triple(FieldKind.PART_B, result.partB, "partB"),
        ).forEach { (kind, f, name) ->
            val crop = f.crop ?: return@forEach
            val fileName = "${stamp}_$name.png"
            File(dir, fileName).writeBytes(crop)
            val e = CorrectionEntry(fileName, name, f.value, modelValues[kind] ?: "", f.confidence, f.edited, now)
            index.appendText(json.encodeToString(CorrectionEntry.serializer(), e) + "\n")
        }
    }

    fun count() = File(dir, "index.jsonl").takeIf { it.exists() }?.readLines()?.size ?: 0
}
