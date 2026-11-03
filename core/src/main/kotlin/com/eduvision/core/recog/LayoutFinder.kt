package com.eduvision.core.recog

import com.eduvision.core.model.FieldKind
import com.eduvision.core.validate.Text
import kotlin.math.max
import kotlin.math.min

/**
 * Places the handwritten fields from the printed labels next to them, so the
 * first sheet of a new layout can be read without a hand-drawn template.
 *
 * Boxes are placed relative to their label in units of the label's own size,
 * which keeps them right on cropped, zoomed or low-resolution photos. They
 * only need to be roughly right: [CellFinder] then snaps each to its printed
 * cell. The offsets come from the CAT answer book in `sample_images/`; a
 * layout with other wording finds nothing here and needs boxes drawn in the
 * template editor.
 */
object LayoutFinder {
    fun locate(lines: List<TextLine>): Map<FieldKind, Box> {
        val labels = lines.map { Text.key(it.text) to it.box }

        // Shortest matching line first: "Registered No." beats the
        // instructions sentence that mentions the registered number.
        fun find(test: (String) -> Boolean) = labels.filter { test(it.first) }
            .minWithOrNull(compareBy({ it.first.length }, { it.second.y0 }))?.second

        val out = LinkedHashMap<FieldKind, Box>()
        // Written on the same row, right of the label.
        find { it.startsWith("registeredno") || it.startsWith("registrationno") || it.startsWith("regdno") || it.startsWith("rollno") || it.startsWith("hallticketno") }?.let { b ->
            val c = (b.y0 + b.y1) / 2
            out[FieldKind.REGISTRATION] = Box(b.x1, c - 0.9 * b.h, b.x1 + 2.9 * b.w, c + 0.7 * b.h)
        }
        // Part totals are written in the cell under their label.
        for ((key, kind) in listOf("partatotal" to FieldKind.PART_A, "partbtotal" to FieldKind.PART_B)) {
            find { it.startsWith(key) && it.length <= key.length + 3 }?.let { b ->
                out[kind] = Box(b.x0 - 0.1 * b.w, b.y1, b.x1 + 0.05 * b.w, b.y1 + 2.6 * b.h)
            }
        }
        // "GRAND" over "TOTAL", left of the cell.
        find { it == "grand" || it == "grandtotal" }?.let { g ->
            var b = g
            for ((key, l) in labels) {
                val below = l.y0 >= b.y0 && l.y0 - b.y1 < b.h
                val overlaps = min(l.x1, b.x1) > max(l.x0, b.x0)
                if (key == "total" && below && overlaps) b = Box(min(b.x0, l.x0), min(b.y0, l.y0), max(b.x1, l.x1), max(b.y1, l.y1))
            }
            out[FieldKind.WRITTEN_TOTAL] = Box(b.x1 + 0.35 * b.w, b.y0 - 0.35 * b.h, b.x1 + 2.2 * b.w, b.y1 + 0.35 * b.h)
        }
        return out
    }
}
