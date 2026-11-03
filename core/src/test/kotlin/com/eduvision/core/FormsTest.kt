package com.eduvision.core

import com.eduvision.core.validate.ScanValidator
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.opencv.imgcodecs.Imgcodecs
import java.io.File

/**
 * Whole-form extraction on the owner's photos (not in the repo: they hold a
 * real name; set FORMS_DIR to a folder with the photos and truth.json).
 */
class FormsTest {
    @Test
    fun findsAndReadsEveryField() {
        val dir = System.getenv("FORMS_DIR")?.let(::File)
        assumeTrue(dir != null && File(dir, "truth.json").exists())
        RealSheetsTest.setUp()
        val truth = Json.parseToJsonElement(File(dir, "truth.json").readText()) as JsonObject
        for ((name, t) in truth) {
            val photo = Imgcodecs.imread(File(dir, name).path, Imgcodecs.IMREAD_GRAYSCALE)
            if (System.getenv("FORMS_LINES") == "1") {
                val ref = com.eduvision.core.recog.Aligner.downscale(photo, com.eduvision.core.recog.SheetReader.REFERENCE_SIDE)
                RealSheetsTest.text.read(ref).forEach { println("   LINE %.0f %.0f %.0f %.0f '%s'".format(it.box.x0, it.box.y0, it.box.x1, it.box.y1, it.text)) }
            }
            val layout = RealSheetsTest.reader.createTemplate(photo, name, name)
            println("== $name: ${layout.template.fields.size} fields")
            layout.template.fields.forEach { f ->
                println("   ${f.kind} '${f.title}' part=${f.part} cells=${f.cells} free=${f.free} opts=${f.options} " +
                    "box=%.3f,%.3f,%.3f,%.3f".format(f.box.left, f.box.top, f.box.right, f.box.bottom))
            }
            val r = ScanValidator.validate(RealSheetsTest.reader.read(photo, layout.template, layout.reference), layout.template)
            val got = linkedMapOf("reg" to r.registrationNo.value, "partA" to r.partA.value, "partB" to r.partB.value)
            (r.questions + r.writtenTotals + r.extras).forEach { got[it.label] = it.field.value + " (%.2f)".format(it.field.confidence) }
            println("   read: $got")
            r.extras.filter { layout.template.fields.any { f -> f.title == it.label && f.kind == com.eduvision.core.model.FieldKind.CHOICE } }
                .forEach { println("   choice ${it.label}: ${it.field.rawText}"); if (System.getenv("DEBUG_DUMP") == "1") it.field.crop?.let { c -> File(RealSheetsTest.root, "core/build/debug").apply { mkdirs() }.resolve("choice_${it.label}.png").writeBytes(c) } }
            val want = t.jsonObject.mapValues { it.value.jsonPrimitive.content }
            println("   want: $want")
            // Score: each wanted field against the reading with the same name.
            fun norm(x: String) = x.lowercase().filter { it.isLetterOrDigit() }
            val values = mutableMapOf<String, Pair<String, Boolean>>()
            values[norm("Registered No.")] = r.registrationNo.value to !r.registrationNo.needsReview
            values[norm("Hall Ticket No.")] = values[norm("Registered No.")]!!
            values[norm("Part-A Total")] = r.partA.value to !r.partA.needsReview
            values[norm("Part-B Total")] = r.partB.value to !r.partB.needsReview
            (r.questions + r.writtenTotals + r.extras).forEach { values[norm(it.label)] = it.field.value to !it.doubtful }
            values[norm("GRAND TOTAL")] = values[norm("Grand total")] ?: ("" to false)
            var right = 0; var found = 0; var silent = 0
            want.forEach { (k, v) ->
                val got = values[norm(k)] ?: return@forEach
                found++
                val ok = norm(got.first) == norm(v)
                if (ok) right++ else if (got.second) silent++
                if (!ok) println("     $k: got '${got.first}'${if (got.second) " (NOT flagged)" else " (flagged)"} want '$v'")
            }
            println("   SCORE $name: found $found/${want.size}, right $right/${want.size}, wrong-but-not-flagged $silent")
        }
    }
}
