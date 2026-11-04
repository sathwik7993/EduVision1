package com.eduvision.core

import com.eduvision.core.model.FieldKind
import com.eduvision.core.recog.FieldModel
import com.eduvision.core.recog.PrintedTextReader
import com.eduvision.core.recog.SheetReader
import com.eduvision.core.validate.ScanValidator
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.opencv.core.Mat
import org.opencv.imgcodecs.Imgcodecs
import java.io.File

/**
 * End-to-end on the 9 real photos in sample_images/ (one layout): the
 * template is created from the printed labels of one clean photo, exactly as
 * the app does on a first scan, then every photo is read through the full
 * pipeline and compared with the hand labels in annotations.json.
 *
 * LOCAL ONLY: the photos hold real registration numbers. This test reads them
 * from disk and prints readings to the console; nothing is uploaded.
 */
class RealSheetsTest {
    companion object {
        val root = File(System.getProperty("repoRoot") ?: "..")
        lateinit var reader: SheetReader
        lateinit var text: PrintedTextReader

        @BeforeClass @JvmStatic
        fun setUp() {
            nu.pattern.OpenCV.loadLocally()
            val models = File(root, "assets/models")
            text = PrintedTextReader(File(models, "ppocr_v3_det.onnx").readBytes(), File(models, "ppocr_v3_rec.onnx").readBytes())
            // FIELD_MODEL / REG_MODEL: candidate models to compare on the real sheets.
            val marks = FieldModel((System.getenv("FIELD_MODEL")?.let(::File) ?: File(models, "field_recognizer_v3.onnx")).readBytes(), threads = 1)
            val reg = System.getenv("REG_MODEL")?.let { FieldModel(File(it).readBytes(), threads = 1) } ?: marks
            // HANDWRITING_REC: a recognition model for handwritten text fields.
            val words = System.getenv("HANDWRITING_REC")?.let { PrintedTextReader(null, File(it).readBytes()) }
            reader = SheetReader(marks, System.getenv("READER_THREADS")?.toInt() ?: SheetReader.defaultThreads(), reg,
                words?.let { w -> { w } }) { text }
        }

        fun gray(name: String): Mat = Imgcodecs.imread(File(root, "sample_images/$name").path, Imgcodecs.IMREAD_GRAYSCALE)

        val annotations: Map<String, Map<String, String>> by lazy {
            val obj = Json.parseToJsonElement(File(root, "sample_images/annotations.json").readText()) as JsonObject
            obj.filterKeys { !it.startsWith("_") }.mapValues { (_, v) ->
                (v as JsonObject).mapValues { (_, f) -> (f.jsonArray[1]).jsonPrimitive.content }
            }
        }
    }

    @Test
    fun layoutIsFoundFromPrintedLabelsOnEveryPhoto() {
        for (name in annotations.keys) {
            val t0 = System.nanoTime()
            val layout = reader.createTemplate(gray(name), "t", "t")
            val ms = (System.nanoTime() - t0) / 1_000_000
            val kinds = layout?.template?.fields?.map { it.kind }.orEmpty()
            println("layout ${name.takeLast(16)}: ${kinds.joinToString()} cells=${layout?.template?.field(FieldKind.REGISTRATION)?.cells} (${ms} ms)")
        }
        val clean = reader.createTemplate(gray(annotations.keys.first { "13.33" in it }), "t", "t")
        assertNotNull(clean)
        assertTrue(clean!!.template.fields.map { it.kind }.containsAll(
            listOf(FieldKind.REGISTRATION, FieldKind.PART_A, FieldKind.PART_B, FieldKind.WRITTEN_TOTAL)))
        // The marks slip's 17 question cells (3 struck cells skipped).
        assertEquals(17, clean.template.fields.count { it.kind == FieldKind.QUESTION })
        assertEquals(10, clean.template.field(FieldKind.REGISTRATION)!!.cells)
    }

    @Test
    fun readsEveryPhotoWithAnAutoTemplate() {
        val layout = reader.createTemplate(gray(annotations.keys.first { "13.33" in it }), "cat", "CAT")!!
        // The teacher confirms the registration format once per layout.
        val template = layout.template.copy(registrationMask = "DDADDADDXX", partBMax = 80)
        var right = 0
        var total = 0
        var silent = 0
        var regRight = 0
        val times = ArrayList<Long>()
        for ((name, labels) in annotations) {
            val photo = gray(name)
            val result = ScanValidator.validate(reader.read(photo, template, layout.reference), template)
            times += result.timingsMs["total"]!!
            if (System.getenv("DEBUG_DUMP") == "1") {
                val dir = File(root, "core/build/debug/crops").apply { mkdirs() }
                val tag = name.takeLast(16).replace(" ", "_").replace(".jpeg", "")
                listOf("reg" to result.registrationNo, "a" to result.partA, "b" to result.partB).forEach { (k, v) ->
                    v.crop?.let { File(dir, "${tag}_$k.png").writeBytes(it) }
                }
            }
            val rows = listOf(
                Triple("registration", result.registrationNo, labels["registration"]),
                Triple("partA", result.partA, labels["partA"]),
                Triple("partB", result.partB, labels["partB"]),
                Triple("grandTotal", result.writtenTotals.firstOrNull()?.field, labels["grandTotal"]),
            )
            val line = rows.filter { it.third != null }.joinToString(" | ") { (f, v, want) ->
                total++
                val ok = v?.value == want
                if (ok) right++
                if (ok && f == "registration") regRight++
                val review = when (f) {
                    "grandTotal" -> result.writtenTotals.first().needsReview
                    else -> v!!.needsReview
                }
                if (!ok && !review) silent++
                "$f=${v?.value}(${"%.2f".format(v?.confidence ?: 0.0)}${if (review) ",review" else ""})" +
                    (if (ok) "" else " WANT $want${if (!review) " SILENT" else ""}") +
                    (v?.issue?.let { " [$it]" } ?: "")
            }
            println("${name.takeLast(16)} ${result.timingsMs} ${result.diagnostics} :: $line")
        }
        println("RESULT right $right/$total, registration $regRight/9, silent errors $silent, ms/sheet median ${times.sorted()[times.size / 2]}")
        // Wrong values must never pass without review.
        assertEquals(0, silent)
        assertTrue("right $right/$total", right >= 32)
        assertTrue("registration $regRight/9", regRight >= 8)
    }
}
