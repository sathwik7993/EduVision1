package com.eduvision.core.recog

import com.eduvision.core.model.ExtractedField
import com.eduvision.core.model.FieldKind
import com.eduvision.core.model.LabelledMark
import com.eduvision.core.model.NormBox
import com.eduvision.core.model.ScanResult
import com.eduvision.core.model.SheetTemplate
import com.eduvision.core.model.TemplateField
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfByte
import org.opencv.core.MatOfDouble
import org.opencv.core.Scalar
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Point
import org.opencv.imgcodecs.Imgcodecs
import kotlin.math.max
import kotlin.math.min

class SheetNotRecognized(message: String) : Exception(message)

/**
 * Reads one photographed sheet.
 *
 * Pipeline: register the photo onto the template's reference image (ORB
 * features, global + regional homography) -> cut out each field rectified ->
 * snap to its printed cell -> read the inside of the cell with the
 * handwriting model (one character per box for a registration comb, with the
 * charset its position allows) -> assemble with per-field confidence.
 *
 * Nothing here guesses silently: a field whose printed box was not found, or
 * that falls outside the photo, is flagged for review whatever the model says.
 */
class SheetReader(
    private val model: FieldModel,
    private val textReader: () -> PrintedTextReader,
) {
    private val aligners = HashMap<String, Pair<Mat, Aligner>>()

    /** A new template for the layout in [photo], found from its printed labels. */
    class NewLayout(val template: SheetTemplate, val reference: Mat)

    /**
     * A new template for the layout in [photo]: the photo becomes the
     * reference image, and the fields the printed labels point to are
     * suggested. The fields can be empty (labels not recognised); the teacher
     * then taps the boxes they want.
     */
    fun createTemplate(photo: Mat, id: String, name: String): NewLayout {
        val reference = Aligner.downscale(photo, REFERENCE_SIDE)
        val lines = textReader().read(reference)
        val found = LinkedHashMap<FieldKind, Pair<Box, Int>>()
        FieldSuggester.suggest(reference, lines).forEach { found[it.kind] = it.box to it.cells }
        // Labels next to boxes without a closed border (cut-off photos): fixed
        // offsets from the label, measured on the CAT answer book.
        LayoutFinder.locate(lines).forEach { (kind, b) ->
            if (kind in found) return@forEach
            val cells = if (kind == FieldKind.REGISTRATION) {
                val (patch, pb) = CellFinder.warpPatch(reference, identity(), b, scaleFor(b), 0.5)
                CellFinder.countCombCells(patch, pb).also { patch.release() }
            } else 0
            found[kind] = b to cells
        }
        val w = reference.cols().toDouble()
        val h = reference.rows().toDouble()
        val fields = found.map { (kind, v) ->
            val b = v.first
            TemplateField(kind, NormBox(b.x0 / w, b.y0 / h, b.x1 / w, b.y1 / h), cells = v.second)
        }
        return NewLayout(SheetTemplate(id = id, name = name, fields = fields, auto = true), reference)
    }

    /**
     * Reads [photo] (8-bit grayscale) with [template], whose reference image
     * is [reference]. Throws [SheetNotRecognized] when the photo does not
     * match the layout.
     */
    fun read(photo: Mat, template: SheetTemplate, reference: Mat, imagePath: String? = null): ScanResult {
        val clock = System.nanoTime()
        val timings = LinkedHashMap<String, Long>()
        var last = clock
        fun lap(stage: String) {
            val now = System.nanoTime(); timings[stage] = (now - last) / 1_000_000; last = now
        }

        val aligner = aligners[template.id]?.takeIf { it.first === reference }?.second
            ?: Aligner(reference).also { aligners[template.id] = reference to it }
        val fit = aligner.fit(photo) ?: throw SheetNotRecognized(
            "This photo does not match the \"${template.name}\" layout. Photograph the whole sheet, " +
                "or choose another template.")
        lap("align")

        val rw = reference.cols().toDouble()
        val rh = reference.rows().toDouble()
        val diagnostics = LinkedHashMap<String, String>()
        val reads = template.fields.map { f ->
            val box = Box(f.box.left * rw, f.box.top * rh, f.box.right * rw, f.box.bottom * rh)
            val (h, score) = bestHomography(photo, reference, fit, box)
            var v = readField(photo, h, box, f, template)
            // The printed text and lines around the box do not look like the
            // template's: the value may come from a neighbouring cell.
            diagnostics[f.title] = "context %.2f".format(score)
            if (score < CONTEXT_MIN) v = v.withIssue("Could not line this box up with the template; check the value")
            f to v
        }
        lap("fields")
        timings["total"] = (System.nanoTime() - clock) / 1_000_000
        timings["inliers"] = fit.inliers.toLong()
        return assemble(reads, imagePath, timings).copy(diagnostics = diagnostics)
    }

    /**
     * Of the global and regional homographies, the one under which the
     * printed surroundings of [box] (labels, cell borders; the handwriting
     * inside is masked out) best correlate with the reference image.
     */
    private fun bestHomography(photo: Mat, reference: Mat, fit: Aligner.Fit, box: Box): Pair<Mat, Double> {
        val scale = 48.0 / max(box.h, 1.0)
        val (ref, rb) = CellFinder.warpPatch(reference, identity(), box, scale.coerceIn(0.5, 3.0), CONTEXT_MARGIN)
        val mask = Mat(ref.size(), CvType.CV_8U, Scalar(255.0))
        Imgproc.rectangle(mask, Point(rb.x0, rb.y0), Point(rb.x1, rb.y1), Scalar(0.0), -1)
        val best = fit.candidates(Point((box.x0 + box.x1) / 2, (box.y0 + box.y1) / 2)).map { h ->
            val (p, _) = CellFinder.warpPatch(photo, h, box, scale.coerceIn(0.5, 3.0), CONTEXT_MARGIN)
            h to correlation(ref, p, mask).also { p.release() }
        }.maxBy { it.second }
        ref.release(); mask.release()
        return best
    }

    private fun correlation(a: Mat, b: Mat, mask: Mat): Double {
        val fa = Mat(); val fb = Mat()
        a.convertTo(fa, CvType.CV_32F); b.convertTo(fb, CvType.CV_32F)
        // Wide enough to forgive a few pixels of residual on thin printed
        // lines, far narrower than the one-row shift this check must catch.
        Imgproc.GaussianBlur(fa, fa, Size(0.0, 0.0), 6.0)
        Imgproc.GaussianBlur(fb, fb, Size(0.0, 0.0), 6.0)
        val ma = MatOfDouble(); val sa = MatOfDouble(); val mb = MatOfDouble(); val sb = MatOfDouble()
        Core.meanStdDev(fa, ma, sa, mask)
        Core.meanStdDev(fb, mb, sb, mask)
        Core.subtract(fa, Scalar(ma.get(0, 0)[0]), fa)
        Core.subtract(fb, Scalar(mb.get(0, 0)[0]), fb)
        val prod = Mat()
        Core.multiply(fa, fb, prod)
        val cov = Core.mean(prod, mask).`val`[0]
        listOf(fa, fb, prod).forEach { it.release() }
        val d = sa.get(0, 0)[0] * sb.get(0, 0)[0]
        return if (d < 1e-6) 0.0 else cov / d
    }

    private fun readField(photo: Mat, h: Mat, box: Box, f: TemplateField, t: SheetTemplate): ExtractedField {
        if (!inside(photo, h, box)) {
            return ExtractedField("", 0.0, issue = "Cut off in the photo")
        }
        val (patch, pb) = CellFinder.warpPatch(photo, h, box, scaleFor(box), 0.5)
        try {
            val text = f.kind == FieldKind.REGISTRATION || f.kind == FieldKind.TEXT
            val combCells = if (f.kind == FieldKind.REGISTRATION) t.registrationLength ?: f.cells else f.cells
            if (combCells > 1) {
                val mask = if (f.kind == FieldKind.REGISTRATION) t.registrationMask
                    else if (text) null else "D".repeat(combCells)
                CellFinder.findComb(patch, pb, combCells)?.let { return readComb(patch, it, mask) }
            }
            val cell = CellFinder.findCell(patch, pb)
            val area = cell?.inset(0.05, 2.0) ?: pb
            val crop = CellFinder.crop(patch, area) ?: return ExtractedField("", 0.0, issue = "Box not found")
            val allowed = if (text) CHARSET else DIGITS
            val r = CtcDecoder.decode(model.run(crop), allowed)
            return ExtractedField(
                r.text, r.confidence, rawText = r.text, crop = png(crop),
                issue = if (cell == null) "Could not find the printed box; check the value" else null,
            )
        } finally {
            patch.release()
        }
    }

    /**
     * One character per printed box, each from the class its position allows.
     * Reading box by box (borders trimmed) beat reading the comb as one strip
     * on the sample sheets: as a strip, CTC merges the "66" of adjacent boxes.
     */
    private fun readComb(patch: Mat, cells: List<Box>, mask: String?): ExtractedField {
        val text = StringBuilder()
        val alt = StringBuilder()
        var hasAlt = false
        var confidence = 1.0
        for ((i, c) in cells.withIndex()) {
            val crop = CellFinder.crop(patch, c.inset(0.06, 1.0)) ?: continue
            val maskChar = mask?.getOrNull(i)
            val r = CtcDecoder.decode(model.run(crop), CtcDecoder.allowedFor(maskChar))
            // A box holds one character; two means the model split a stroke.
            val ch = r.text.take(1)
            text.append(ch)
            confidence = min(confidence, r.confidence)
            val swap = ch.firstOrNull()?.let { confusable(it, maskChar) }
            if (swap != null) { alt.append(swap); hasAlt = true } else alt.append(ch)
        }
        val crop = CellFinder.crop(patch, Box(cells.first().x0, cells.first().y0, cells.last().x1, cells.first().y1))
        return ExtractedField(
            text.toString(), confidence, rawText = text.toString(), crop = crop?.let(::png),
            alternative = if (hasAlt) alt.toString() else null,
        )
    }

    private fun assemble(reads: List<Pair<TemplateField, ExtractedField>>, imagePath: String?, timings: Map<String, Long>): ScanResult {
        fun of(kind: FieldKind) = reads.firstOrNull { it.first.kind == kind }?.second ?: ExtractedField.EMPTY
        return ScanResult(
            registrationNo = of(FieldKind.REGISTRATION),
            partA = of(FieldKind.PART_A),
            partB = of(FieldKind.PART_B),
            questions = reads.filter { it.first.kind == FieldKind.QUESTION }
                .map { (f, v) -> LabelledMark(f.label.ifEmpty { "Question" }, f.part, v, f.maxMarks) },
            writtenTotals = reads.filter { it.first.kind == FieldKind.WRITTEN_TOTAL }
                .map { (f, v) -> LabelledMark(f.title, "", v) },
            extras = reads.filter { it.first.kind == FieldKind.MARK || it.first.kind == FieldKind.TEXT }
                .map { (f, v) -> LabelledMark(f.title, "", v, f.maxMarks) },
            imagePath = imagePath,
            alignment = "features",
            timingsMs = timings,
        )
    }

    /** Field corners must land inside the photo (2% slack). */
    private fun inside(photo: Mat, h: Mat, b: Box): Boolean {
        val out = MatOfPoint2f()
        Core.perspectiveTransform(MatOfPoint2f(Point(b.x0, b.y0), Point(b.x1, b.y0), Point(b.x1, b.y1), Point(b.x0, b.y1)), out, h)
        val sx = 0.02 * photo.cols()
        val sy = 0.02 * photo.rows()
        return out.toArray().all { it.x >= -sx && it.y >= -sy && it.x <= photo.cols() + sx && it.y <= photo.rows() + sy }
    }

    companion object {
        /** Context around a field compared with the reference, in box sizes. */
        const val CONTEXT_MARGIN = 1.0

        /** Below this context correlation the field is flagged as possibly misaligned. */
        const val CONTEXT_MIN = 0.5

        /** Longer side of a stored reference image. */
        const val REFERENCE_SIDE = 1600

        /** Patch scale giving a field ~96 px tall: plenty for a 32 px model input. */
        fun scaleFor(b: Box) = (96.0 / max(b.h, 1.0)).coerceIn(1.0, 6.0)

        fun identity(): Mat = Mat.eye(3, 3, CvType.CV_64F)

        fun png(m: Mat): ByteArray {
            val buf = MatOfByte()
            Imgcodecs.imencode(".png", m, buf)
            return buf.toArray()
        }

        /**
         * Pairs a model trained on EMNIST mixes up, offered only where the
         * position allows both classes: a digit box cannot hold "D".
         */
        private val pairs = mapOf(
            '0' to 'D', 'D' to '0', 'O' to '0', '1' to 'I', 'I' to '1', '5' to 'S', 'S' to '5',
            '2' to 'Z', 'Z' to '2', '8' to 'B', 'B' to '8', '6' to 'G', 'G' to '6',
        )

        fun confusable(c: Char, maskChar: Char?): Char? =
            if (maskChar == null || maskChar.uppercaseChar() == 'X') pairs[c] else null
    }
}
