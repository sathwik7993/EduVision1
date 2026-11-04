package com.eduvision.core.recog

import com.eduvision.core.model.FieldKind
import com.eduvision.core.validate.Text
import org.opencv.core.Mat
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Suggests fields on a sample sheet of any layout: finds printed labels by
 * meaning (many wordings: "Registered No.", "Roll Number", "Hall Ticket No",
 * "Section A", "Total Marks"...) and pairs each with the empty printed box
 * beside or below it. The teacher confirms or corrects the suggestions and
 * taps any other box they want; nothing here is tied to one college's sheet.
 */
object FieldSuggester {
    data class Suggestion(val kind: FieldKind, val box: Box, val cells: Int, val label: String)

    private val registration = listOf(
        "registeredno", "registerednumber", "registrationno", "registrationnumber", "registerno", "regno", "regdno",
        "rollno", "rollnumber", "hallticket", "htno", "enrolmentno", "enrollmentno", "enrolno", "admissionno",
        "usn", "prn", "seatno", "studentid", "candidateid", "examno", "examinationno", "idno", "universityno",
    )
    private val partA = Regex("^(total)?(part|section|sec)a(total|marks)?$")
    private val partB = Regex("^(total)?(part|section|sec)b(total|marks)?$")
    private val grand = setOf("grandtotal", "grand", "totalmarks", "marksobtained", "totalmarksobtained", "total", "totalscore", "grandtotalmarks", "overalltotal")

    fun kindOf(key: String): FieldKind? = when {
        // Short lines only: the instructions also mention the registered number.
        key.length <= 24 && registration.any { key.startsWith(it) || (it.length >= 6 && it in key && key.length <= it.length + 8) } -> FieldKind.REGISTRATION
        partA.matches(key) -> FieldKind.PART_A
        partB.matches(key) -> FieldKind.PART_B
        key in grand -> FieldKind.WRITTEN_TOTAL
        else -> null
    }

    fun suggest(page: Mat, lines: List<TextLine>): List<Suggestion> {
        val keyed = lines.map { Text.key(it.text) to it }
        val out = ArrayList<Suggestion>()
        for (kind in listOf(FieldKind.REGISTRATION, FieldKind.PART_A, FieldKind.PART_B, FieldKind.WRITTEN_TOTAL)) {
            // A label that says "total" first ("Part-A Total" over the
            // "PART-A" row heading), then the shortest, then the lowest on the
            // page (the marks slip usually sits below the instructions).
            val candidates = keyed.filter { kindOf(it.first) == kind }
                .sortedWith(compareBy({ if ("total" in it.first) 0 else 1 }, { it.first.length }, { -it.second.box.y0 }))
            for ((_, line) in candidates) {
                var label = line.box
                if (Text.key(line.text) == "grand") {
                    // "GRAND" over "TOTAL": one label.
                    keyed.firstOrNull { (k, l) -> k == "total" && l.box.y0 >= label.y0 && l.box.y0 - label.y1 < label.h &&
                        min(l.box.x1, label.x1) > max(l.box.x0, label.x0) }?.let { (_, l) ->
                        label = Box(min(label.x0, l.box.x0), label.y0, max(label.x1, l.box.x1), l.box.y1)
                    }
                }
                val found = boxFor(page, label, keyed.map { it.second }, kind == FieldKind.REGISTRATION) ?: continue
                if (out.any { it.box.iou(found.first) > 0.3 }) continue
                out += Suggestion(kind, found.first, found.second, line.text)
                break
            }
        }
        return out
    }

    /** The empty printed box right of or below [label]; (box, comb cells). */
    private fun boxFor(page: Mat, label: Box, lines: List<TextLine>, comb: Boolean): Pair<Box, Int>? {
        val lh = max(label.h, 8.0)
        val cy = (label.y0 + label.y1) / 2
        val cx = (label.x0 + label.x1) / 2
        val right = listOf(0.6, 1.5, 3.0, 5.0).map { Triple(label.x1 + it * lh, cy, true) }
        val below = listOf(0.7, 1.5, 2.5).map { Triple(cx, label.y1 + it * lh, false) }
        for ((x, y, isRight) in right + below) {
            if (x >= page.cols() || y >= page.rows()) continue
            val p = CellFinder.boxAt(page, x, y) ?: continue
            val cell = p.cell
            if (label.x0 + 2 >= cell.x0 && label.x1 - 2 <= cell.x1 && label.y0 + 2 >= cell.y0 && label.y1 - 2 <= cell.y1) continue
            if (cell.h < 0.8 * lh || cell.h > 8 * lh || cell.w < 0.9 * lh) continue
            if (isRight && abs((cell.y0 + cell.y1) / 2 - cy) > 1.2 * lh) continue
            if (!isRight && min(cell.x1, label.x1) - max(cell.x0, label.x0) < 0.3 * min(label.w, cell.w)) continue
            if (hasPrintedText(cell, lines)) continue
            return if (comb && p.row != null && p.rowCells >= 4) p.row to p.rowCells else cell to 0
        }
        return null
    }

    /**
     * A printed word inside means a label cell, not a field. Handwriting the
     * OCR happened to read ("10", "23H51A66K1") has no run of four letters.
     */
    private fun hasPrintedText(cell: Box, lines: List<TextLine>) = lines.any { l ->
        val x = (l.box.x0 + l.box.x1) / 2
        val y = (l.box.y0 + l.box.y1) / 2
        x in cell.x0..cell.x1 && y in cell.y0..cell.y1 && Regex("[A-Za-z]{4,}").containsMatchIn(l.text)
    }
}
