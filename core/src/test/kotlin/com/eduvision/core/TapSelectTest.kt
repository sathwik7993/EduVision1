package com.eduvision.core

import com.eduvision.core.recog.Box
import com.eduvision.core.recog.CellFinder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** A tap inside a printed box selects that box (what the teacher does in the layout editor). */
class TapSelectTest {
    private fun annotated(name: String): Map<String, Box> {
        val obj = Json.parseToJsonElement(File(RealSheetsTest.root, "sample_images/annotations.json").readText()) as JsonObject
        return (obj[name] as JsonObject).mapValues { (_, v) ->
            val b = v.jsonArray[0].jsonArray.map { it.jsonPrimitive.content.toDouble() }
            Box(b[0], b[1], b[2], b[3])
        }
    }

    @Test
    fun tapSnapsToPrintedBoxes() {
        RealSheetsTest.setUp()
        for (name in RealSheetsTest.annotations.keys.filter { "13.33" in it || "13.28" in it || "13.31" in it }) {
            val page = RealSheetsTest.gray(name)
            val boxes = annotated(name)
            for (f in listOf("partA", "partB", "grandTotal", "registration")) {
                val want = boxes[f] ?: continue
                val p = CellFinder.boxAt(page, (want.x0 + want.x1) / 2, (want.y0 + want.y1) / 2)
                val got = if (f == "registration") p?.row else p?.cell
                println("${name.takeLast(16)} $f -> ${p?.cell?.let { "%.0f,%.0f,%.0f,%.0f".format(it.x0, it.y0, it.x1, it.y1) }} row=${p?.rowCells} iou=${got?.iou(want)}")
                assertNotNull("$name $f", got)
                assertTrue("$name $f iou ${got!!.iou(want)}", got.iou(want) > 0.5)
                if (f == "registration") assertEquals(10, p!!.rowCells)
            }
        }
    }
}
