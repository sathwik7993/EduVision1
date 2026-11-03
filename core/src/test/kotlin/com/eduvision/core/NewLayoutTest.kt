package com.eduvision.core

import com.eduvision.core.model.FieldKind
import com.eduvision.core.model.NormBox
import com.eduvision.core.model.TemplateField
import com.eduvision.core.recog.CellFinder
import com.eduvision.core.validate.ScanValidator
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.opencv.imgcodecs.Imgcodecs
import java.io.File

/**
 * A layout the code was never tuned on (training/synthetic/make_sheet.py
 * sheet_b: "Hall Ticket No." with the boxes underneath, a table whose column
 * headings are "Section A / Section B / Internal / Total Marks"). Set up the
 * way a teacher does it: suggestions from one sample, plus one tap for a
 * custom "Internal" column; then three photos are read automatically.
 */
class NewLayoutTest {
    @Test
    fun suggestedFieldsPlusOneTapReadAnotherLayout() {
        RealSheetsTest.setUp()
        val dir = File(RealSheetsTest.root, "app/src/androidTest/assets/bench")
        val gray = { n: String -> Imgcodecs.imread(File(dir, n).path, Imgcodecs.IMREAD_GRAYSCALE) }
        val layout = RealSheetsTest.reader.createTemplate(gray("b_sheet_clean.png"), "b", "Greenfield")
        val ref = layout.reference
        println("suggested: " + layout.template.fields.joinToString { "${it.kind}(${it.cells})" })
        assertEquals(setOf(FieldKind.REGISTRATION, FieldKind.PART_A, FieldKind.PART_B, FieldKind.WRITTEN_TOTAL),
            layout.template.fields.map { it.kind }.toSet())
        assertEquals(10, layout.template.field(FieldKind.REGISTRATION)!!.cells)

        // The teacher taps inside the "Internal" marks box (sheet_b geometry,
        // 1240 x 1754 page, scaled to the reference).
        val s = ref.cols() / 1240.0
        val picked = CellFinder.boxAt(ref, 740 * s, 1325 * s)
        assertNotNull(picked)
        val c = picked!!.cell
        val internal = TemplateField(FieldKind.MARK,
            NormBox(c.x0 / ref.cols(), c.y0 / ref.rows(), c.x1 / ref.cols(), c.y1 / ref.rows()), label = "Internal", maxMarks = 20)
        val template = layout.template.copy(fields = layout.template.fields + internal,
            registrationMask = "DDADDADDXX", partAMax = 40, partBMax = 60)

        val truth = Json.parseToJsonElement(File(dir, "truth_b.json").readText()) as JsonObject
        var right = 0
        var total = 0
        for ((name, t) in truth) {
            val r = ScanValidator.validate(RealSheetsTest.reader.read(gray(name), template, ref), template)
            val want = t.jsonObject.mapValues { it.value.jsonPrimitive.content }
            val got = mapOf("registration" to r.registrationNo.value, "partA" to r.partA.value, "partB" to r.partB.value,
                "internal" to r.extras.first { it.label == "Internal" }.field.value)
            got.forEach { (k, v) -> total++; if (v == want[k]) right++ }
            println("$name got $got want $want ${r.timingsMs}")
        }
        println("LAYOUT_B right $right/$total")
        assertTrue("right $right/$total", right >= total - 1)
    }
}
