package com.eduvision.core

import com.eduvision.core.validate.ScanValidator
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.opencv.imgcodecs.Imgcodecs
import java.io.File

/**
 * The synthetic sheets the device benchmark uses (app/src/androidTest/assets/
 * bench, from training/synthetic/make_sheet.py): what the phones in Test Lab
 * should read, checked on the desktop first.
 */
class SyntheticSheetsTest {
    @Test
    fun readsSyntheticPhotos() {
        RealSheetsTest.setUp()
        val dir = File(RealSheetsTest.root, "app/src/androidTest/assets/bench")
        val gray = { n: String -> Imgcodecs.imread(File(dir, n).path, Imgcodecs.IMREAD_GRAYSCALE) }
        val layout = RealSheetsTest.reader.createTemplate(gray("sheet_clean.png"), "syn", "Synthetic")
        assertNotNull(layout)
        val template = layout!!.template.copy(registrationMask = "DDADDADDXX", partBMax = 60)
        val truth = Json.parseToJsonElement(File(dir, "truth.json").readText()) as JsonObject
        var right = 0
        var total = 0
        for ((name, t) in truth) {
            val r = ScanValidator.validate(RealSheetsTest.reader.read(gray(name), template, layout.reference), template)
            val want = t.jsonObject.mapValues { it.value.jsonPrimitive.content }
            listOf(r.registrationNo.value to want["registration"], r.partA.value to want["partA"], r.partB.value to want["partB"])
                .forEach { (got, w) -> total++; if (got == w) right++ }
            println("$name ${r.registrationNo.value} ${r.partA.value} ${r.partB.value} ${r.timingsMs} want $want")
        }
        println("SYNTHETIC right $right/$total")
        assertTrue(template.fields.map { it.kind.name }.containsAll(listOf("REGISTRATION", "PART_A", "PART_B", "WRITTEN_TOTAL")))
        org.junit.Assert.assertTrue("right $right/$total", right >= 11)
    }
}
