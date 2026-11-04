package com.eduvision.core.recog

import com.eduvision.core.model.FieldKind
import com.eduvision.core.validate.Text
import org.opencv.core.Mat
import org.opencv.core.Rect
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Finds every field a teacher would want from a sample sheet, beyond the
 * registration number and totals [FieldSuggester] pairs with their labels:
 *
 * - marks tables: each cell of a row labelled "Marks", named by the heading
 *   cell above it (a question number, "Part-A Total", "GRAND TOTAL"; struck
 *   "—" cells skipped), with its part from a "PART-A"/"PART-B" row label;
 * - label lines: "Name of the Student : ____", "Branch : ____", any printed
 *   label followed by space to write in, read as text;
 * - tick choices: a label followed by printed options separated by "/"
 *   ("Programme : B.Tech / M.Tech / MBA"), read by which option is marked.
 *
 * Works from the page's own structure and wording, not from one college's
 * layout; anything it misses the teacher adds with a tap.
 */
object FormFinder {
    data class Found(
        val kind: FieldKind,
        val box: Box,
        val label: String,
        val part: String = "A",
        val free: Boolean = false,
        val options: List<String> = emptyList(),
        val optionBoxes: List<Box> = emptyList(),
    )

    /** Common printed form labels (compact key -> display name), longest first. */
    private val labels = listOf(
        "nameofthestudent" to "Name of the Student", "nameofstudent" to "Name of the Student", "studentname" to "Student Name",
        "nameofthecandidate" to "Name of the Candidate", "candidatename" to "Candidate Name",
        "dateofexamination" to "Date of Exam", "dateofexam" to "Date of Exam", "academicyear" to "Academic Year",
        "coursename" to "Course Name", "coursecode" to "Course Code", "coursetitle" to "Course Title",
        "subjectname" to "Subject Name", "subjectcode" to "Subject Code", "papercode" to "Paper Code",
        "department" to "Department", "programme" to "Programme", "program" to "Programme", "regulation" to "Regulation",
        "semester" to "Semester", "section" to "Section", "subject" to "Subject", "branch" to "Branch", "course" to "Course",
        "grandtotalinwords" to "Grand Total in Words", "totalinwords" to "Total in Words", "marksinwords" to "Marks in Words",
        "faculty" to "Faculty", "class" to "Class", "batch" to "Batch", "year" to "Year",
        "date" to "Date", "name" to "Name", "mid" to "Mid", "sem" to "Semester",
    ).sortedByDescending { it.first.length }

    /** Printed lines that are never a field to read. */
    private val ignore = listOf("signature", "stamp", "instruction", "examineronly", "filledby", "marksslip", "marksawarded",
        "invigilator", "controller", "scrutinizer", "booklet", "capitalletters", "university", "college", "autonomous",
        "institution", "withdate", "natureof")

    /**
     * The known label [key] starts with, allowing an OCR slip or two
     * ("namefthestudent"); first = how many key characters it covers.
     */
    private fun known(key: String): Pair<Int, String>? {
        for ((phrase, display) in labels) {
            val allowed = when { phrase.length >= 9 -> 2; phrase.length >= 6 -> 1; else -> 0 }
            for (len in listOf(phrase.length, phrase.length - 1, phrase.length + 1)) {
                if (len < 3 || len > key.length) continue
                if (Text.editDistance(key.take(len), phrase) <= allowed) return len to display
            }
        }
        return null
    }

    fun find(page: Mat, lines: List<TextLine>, taken: List<Box>): List<Found> {
        val out = ArrayList<Found>()
        val used = HashSet<TextLine>()
        fun free(b: Box) = (taken + out.map { it.box }).none { o -> o.iou(b) > 0.25 || contains(o, b) || contains(b, o) }

        // Marks tables.
        var nextQ = 1
        val markRows = lines.filter { Text.key(it.text) == "marks" }.sortedBy { it.box.y0 }
        for (m in markRows) {
            used += m
            val rowCells = cellsRightOf(page, m.box) ?: continue
            val rowBand = rowCells.first()
            val part = lines.filter { l ->
                Regex("^part[ab]$").matches(Text.key(l.text)) && l.box.x1 <= m.box.x1 &&
                    l.box.y1 > rowBand.y0 - 2 * rowBand.h && l.box.y0 < rowBand.y1
            }.minByOrNull { abs((it.box.y0 + it.box.y1) / 2 - (rowBand.y0 + rowBand.y1) / 2) }
                ?.let { Text.key(it.text).last().uppercase() } ?: "A"
            for (c in rowCells) {
                val head = headingAbove(page, c, lines)
                head.second.forEach { used += it }
                val key = Text.key(head.first)
                val kind = when {
                    key.startsWith("partatotal") || key == "totalparta" -> FieldKind.PART_A
                    key.startsWith("partbtotal") || key == "totalpartb" -> FieldKind.PART_B
                    "total" in key -> FieldKind.WRITTEN_TOTAL
                    // Struck out: a dash, which the (Chinese/English) OCR may
                    // read as "一", "二", "三": no Latin letter or digit at all.
                    head.first.isNotBlank() && head.first.none { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' } -> null
                    else -> FieldKind.QUESTION
                }
                if (kind == null || !free(c)) continue
                val label = when (kind) {
                    FieldKind.QUESTION -> {
                        val n = head.first.filter(Char::isDigit).toIntOrNull()?.takeIf { it in 1..99 } ?: nextQ
                        nextQ = n + 1
                        "Q$n"
                    }
                    FieldKind.WRITTEN_TOTAL -> "Grand total"
                    else -> ""
                }
                out += Found(kind, c, label, part)
            }
        }

        // Label lines and tick choices.
        val pageCx = page.cols() / 2.0
        val sorted = lines.sortedWith(compareBy({ it.box.y0 }, { it.box.x0 }))
        // Printed character width, from lines that are exactly a known label:
        // locates the end of a label inside a line the OCR joined with the
        // handwriting after it, whose letters are wider.
        val charW = sorted.mapNotNull { l ->
            val key = Text.key(l.text); val k = known(key)
            if (k != null && k.first >= key.length - 1 && key.length >= 4) l.box.w / l.text.trim().length else null
        }.sorted().let { if (it.isEmpty()) null else it[it.size / 2] }
        fun skip(l: TextLine, why: String) { if (DEBUG) println("FormFinder skip '${l.text}': $why") }
        for (l in sorted) {
            if (l in used) continue
            val key = Text.key(l.text)
            if (key.length < 3 || ignore.any { it in key }) continue
            if (taken.any { contains(it, l.box) }) continue
            val k = known(key)
            val colon = l.text.indexOf(':')
            if (k == null && colon < 0) continue
            // A centred line that is not a known label is a title or an
            // address ("Kandlakoya, Medchal, Hyderabad - 501 401."), not a label.
            if (k == null && abs((l.box.x0 + l.box.x1) / 2 - pageCx) < 0.08 * page.cols() && l.box.w > 0.2 * page.cols()) { skip(l, "centred"); continue }
            // Where the printed label ends inside the OCR line (the reader
            // often joins "Branch : CSM" into one line).
            val labelChars = if (k != null) charsCovering(l.text, k.first) else colon
            val after = l.text.substring(min(l.text.length, labelChars)).trimStart(':', ' ', '.', '-')
            val proportional = l.box.x0 + l.box.w * labelChars / max(1, l.text.length)
            val labelEnd = if (after.isNotEmpty() && charW != null) min(proportional, l.box.x0 + charW * labelChars) else proportional
            val name = k?.second ?: l.text.substring(0, colon).trim().trimEnd('.', ':').ifEmpty { continue }
            val lh = l.box.h
            val cy = (l.box.y0 + l.box.y1) / 2

            // Printed options right after the label: a tick choice.
            var optSrc: TextLine? = null
            val optionText = when {
                '/' in after -> after.also { optSrc = l }
                else -> sorted.firstOrNull { o -> o !== l && o !in used && abs((o.box.y0 + o.box.y1) / 2 - cy) < 0.6 * lh &&
                    o.box.x0 >= labelEnd - 2 && o.box.x0 - labelEnd < 2.5 * lh && '/' in o.text }
                    ?.also { optSrc = it }?.text?.trimStart(':', ' ')
            }
            val src = optSrc
            if (optionText != null && src != null) {
                val segments = optionText.split('/')
                if (segments.size >= 2) {
                    val start = if (src === l) labelEnd else src.box.x0 + (src.box.w * (src.text.length - optionText.length) / max(1, src.text.length))
                    var opts = segments.map { it.trim().trim(':', '.', ' ') }
                    // Roman numerals ("I / II / III / IV") come out of the OCR
                    // as 1s, slashes and Vs: name them by position.
                    if (opts.all { o -> o.all { it in "1IlVv|i" } }) opts = opts.indices.map { ROMAN[min(it, ROMAN.lastIndex)] }
                    val boxes = splitSegments(src, start, optionText)
                    val whole = Box(boxes.first().x0, boxes.minOf { it.y0 }, boxes.last().x1, boxes.maxOf { it.y1 })
                    if (free(whole)) out += Found(FieldKind.CHOICE, whole, name, free = true, options = opts, optionBoxes = boxes)
                    used += l; used += src
                    continue
                }
            }

            // Writing space: from the label to the next label, printed rule or page edge.
            val x0 = labelEnd + 0.15 * lh
            // Any printed label or heading that overlaps the row's height
            // ends the writing space, even one sitting half a line higher.
            val rowTop = cy - 0.85 * lh; val rowBottom = cy + 0.7 * lh
            val nextLabel = sorted.filter { o -> o !== l && o.box.x0 > x0 + lh &&
                min(o.box.y1, rowBottom) - max(o.box.y0, rowTop) > 0.3 * o.box.h &&
                (known(Text.key(o.text)) != null || ':' in o.text.drop(1) || ignore.any { it in Text.key(o.text) }) }
                .minOfOrNull { it.box.x0 }
            // A printed border runs above and below the line; a handwritten
            // "I" or "/" does not.
            val rule = firstVerticalRule(page, x0 + lh, cy, 1.6 * lh)
            val contentRight = lines.maxOf { it.box.x1 }
            val x1 = listOfNotNull(nextLabel?.minus(0.3 * lh), rule?.minus(0.2 * lh), contentRight).min()
            if (x1 - x0 < 2.5 * lh) { skip(l, "no room: x0=$x0 next=$nextLabel rule=$rule"); continue }
            // Up to the printed lines above and below, so they are not read as the value.
            val others = sorted.filter { o -> o !== l && min(o.box.x1, x1) - max(o.box.x0, x0) > 0 &&
                abs((o.box.y0 + o.box.y1) / 2 - cy) > 0.6 * lh }
            val top = max(cy - 0.85 * lh, others.filter { it.box.y1 < cy }.maxOfOrNull { it.box.y1 + 1 } ?: Double.NEGATIVE_INFINITY)
            val bottom = min(cy + 0.7 * lh, others.filter { it.box.y0 > cy }.minOfOrNull { it.box.y0 - 1 } ?: Double.POSITIVE_INFINITY)
            val box = Box(x0, top, x1, bottom)
            if (!free(box)) { skip(l, "overlaps another field"); continue }
            out += Found(FieldKind.TEXT, box, name, free = true)
            used += l
        }
        return out
    }

    private val ROMAN = listOf("I", "II", "III", "IV", "V", "VI", "VII", "VIII")
    var DEBUG = System.getenv("FORM_DEBUG") == "1"

    /** Each "/"-separated option's box, by its character span in the OCR line. */
    private fun splitSegments(src: TextLine, startX: Double, optionText: String): List<Box> {
        val total = max(1, optionText.length)
        val width = src.box.x1 - startX
        val out = ArrayList<Box>()
        var from = 0
        for (seg in optionText.split('/')) {
            val to = from + seg.length
            out += Box(startX + width * from / total, src.box.y0, startX + width * max(to, from + 1) / total, src.box.y1)
            from = to + 1
        }
        return out
    }

    /** Characters of [text] needed to cover the first [keyLen] letters/digits. */
    private fun charsCovering(text: String, keyLen: Int): Int {
        var n = 0
        for ((i, c) in text.withIndex()) {
            if (c.isLetterOrDigit()) n++
            if (n == keyLen) {
                var j = i + 1
                while (j < text.length && (text[j] == ':' || text[j] == '.' || text[j] == ' ')) j++
                return j
            }
        }
        return text.length
    }

    /**
     * The cells of the table row to the right of a row label ("Marks"):
     * equal cells and the cells after them, until the row ends.
     */
    private fun cellsRightOf(page: Mat, label: Box): List<Box>? {
        val labelCell = CellFinder.boxAt(page, (label.x0 + label.x1) / 2, (label.y0 + label.y1) / 2)?.cell ?: return null
        val out = ArrayList<Box>()
        var x = labelCell.x1 + 0.3 * labelCell.h
        val cy = (labelCell.y0 + labelCell.y1) / 2
        while (x < page.cols()) {
            val p = CellFinder.boxAt(page, x, cy) ?: break
            val c = p.cell
            if (c.x0 < (out.lastOrNull()?.x1 ?: labelCell.x1) - 3) break
            if (abs(c.h - labelCell.h) > 0.45 * labelCell.h) break
            if (p.row != null && p.rowCells >= 2 && abs(p.row.x0 - c.x0) < 3) {
                val w = p.row.w / p.rowCells
                for (i in 0 until p.rowCells) out += Box(p.row.x0 + i * w, c.y0, p.row.x0 + (i + 1) * w, c.y1)
                x = p.row.x1 + 0.3 * c.h
            } else {
                out += c
                x = c.x1 + 0.3 * c.h
            }
        }
        return out.takeIf { it.isNotEmpty() }
    }

    /** The heading cell above [cell] and the text printed in it. */
    private fun headingAbove(page: Mat, cell: Box, lines: List<TextLine>): Pair<String, List<TextLine>> {
        val cx = (cell.x0 + cell.x1) / 2
        val head = CellFinder.boxAt(page, cx, cell.y0 - 0.35 * cell.h)?.cell
            ?.takeIf { it.y1 <= cell.y0 + 6 && it.y1 > cell.y0 - 1.5 * cell.h } ?: return "" to emptyList()
        val inside = lines.filter { l ->
            val x = (l.box.x0 + l.box.x1) / 2; val y = (l.box.y0 + l.box.y1) / 2
            x in head.x0..head.x1 && y in head.y0..head.y1
        }
        if (inside.isNotEmpty()) return inside.joinToString(" ") { it.text } to inside
        // Small print the OCR skipped: a short dash in an otherwise empty
        // heading means the column is struck out.
        return (if (hasDash(page, head)) "—" else "") to emptyList()
    }

    private fun hasDash(page: Mat, b: Box): Boolean {
        val r = Rect(b.x0.toInt() + 3, b.y0.toInt() + 3, max(1, b.w.toInt() - 6), max(1, b.h.toInt() - 6))
        if (r.x + r.width > page.cols() || r.y + r.height > page.rows()) return false
        val th = CellFinder.ink(page.submat(r))
        val pts = org.opencv.core.MatOfPoint()
        org.opencv.core.Core.findNonZero(th, pts)
        val a = pts.toArray()
        th.release()
        if (a.size < 6) return false
        val w = a.maxOf { it.x } - a.minOf { it.x }
        val h = a.maxOf { it.y } - a.minOf { it.y }
        return w > 3 * max(h, 1.0) && w < 0.8 * r.width
    }

    /**
     * x of the first printed vertical rule right of [fromX] that runs through
     * the row (centre [cy]) for at least [minRun] pixels, or null. Box borders
     * are long; handwritten strokes are not.
     */
    private fun firstVerticalRule(page: Mat, fromX: Double, cy: Double, minRun: Double): Double? {
        val x = fromX.toInt().coerceIn(0, page.cols() - 1)
        val top = (cy - 1.5 * minRun).toInt().coerceIn(0, page.rows() - 1)
        val bottom = (cy + 1.5 * minRun).toInt().coerceIn(top + 1, page.rows())
        val band = page.submat(Rect(x, top, page.cols() - x, bottom - top))
        val th = CellFinder.ink(band)
        // Tolerate a slightly tilted rule.
        org.opencv.imgproc.Imgproc.dilate(th, th, org.opencv.imgproc.Imgproc.getStructuringElement(
            org.opencv.imgproc.Imgproc.MORPH_RECT, org.opencv.core.Size(5.0, 1.0)))
        val mid = (cy - top).toInt().coerceIn(0, th.rows() - 1)
        val colBuf = ByteArray(th.rows())
        var found: Double? = null
        val colMat = Mat()
        for (c in 0 until th.cols()) {
            th.col(c).copyTo(colMat)
            colMat.get(0, 0, colBuf)
            if (colBuf[mid].toInt() == 0) continue
            var up = mid; while (up > 0 && colBuf[up - 1].toInt() != 0) up--
            var dn = mid; while (dn < colBuf.size - 1 && colBuf[dn + 1].toInt() != 0) dn++
            if (dn - up >= minRun) { found = (x + c).toDouble(); break }
        }
        th.release(); colMat.release()
        return found
    }

    private fun contains(o: Box, b: Box) = b.x0 >= o.x0 - 2 && b.x1 <= o.x1 + 2 && b.y0 >= o.y0 - 2 && b.y1 <= o.y1 + 2
}
