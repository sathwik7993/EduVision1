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
import org.opencv.core.Rect
import org.opencv.imgcodecs.Imgcodecs
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.abs
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
    /** Reads marks (digits); also everything else when [regModel] is not given. */
    private val model: FieldModel,
    private val threads: Int = 1,
    /** Reads registration numbers and other letter+digit boxes. */
    private val regModel: FieldModel = model,
    /** Reads handwritten words (names, courses); the printed-label reader when not given. */
    private val handwriting: (() -> PrintedTextReader)? = null,
    /** Read each box under small crop changes and let the readings vote (see [readVoted]). */
    private val augment: Boolean = true,
    /** A second, differently trained model; a box it reads otherwise goes to review. */
    private val checkModel: FieldModel? = null,
    private val textReader: () -> PrintedTextReader,
) {
    private fun wordReader() = handwriting?.invoke() ?: textReader()

    private val aligners = HashMap<String, Pair<Mat, Aligner>>()

    /** Worker threads for the fields of one sheet; daemon threads, so they never keep a JVM alive. */
    private val pool = Executors.newFixedThreadPool(threads.coerceAtLeast(1)) { r ->
        Thread(r, "sheet-reader").apply { isDaemon = true }
    }

    private fun <T, R> java.util.concurrent.ExecutorService.submitAll(items: List<T>, f: (T) -> R): List<R> =
        if (threads <= 1) items.map(f)
        else items.map { submit<R> { f(it) } }.map {
            try { it.get() } catch (e: ExecutionException) { throw e.cause ?: e }
        }

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
        fun norm(b: Box) = NormBox(b.x0 / w, b.y0 / h, b.x1 / w, b.y1 / h)
        val fields = found.map { (kind, v) -> TemplateField(kind, norm(v.first), cells = v.second) } +
            // Everything else on the sheet: marks tables, label lines, tick choices.
            FormFinder.find(reference, lines, found.values.map { it.first }).map { f ->
                TemplateField(f.kind, norm(f.box), label = f.label, part = f.part, free = f.free,
                    options = f.options, optionBoxes = f.optionBoxes.map(::norm))
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
        val contextNs = AtomicLong()
        val readNs = AtomicLong()
        if (template.fields.any { it.kind == FieldKind.TEXT }) wordReader() // created once, before the threads
        // Fields are independent: read them on several cores at once. The
        // model and OpenCV calls are thread-safe; the caches they share are
        // concurrent maps.
        val reads = pool.submitAll(template.fields) { f ->
            val box = Box(f.box.left * rw, f.box.top * rh, f.box.right * rw, f.box.bottom * rh)
            val c0 = System.nanoTime()
            val (h, score) = bestHomography(photo, reference, fit, box)
            val c1 = System.nanoTime()
            var v = readField(photo, h, box, f, template, rw, rh)
            contextNs.addAndGet(c1 - c0); readNs.addAndGet(System.nanoTime() - c1)
            // The printed text and lines around the box do not look like the
            // template's: the value may come from a neighbouring cell.
            if (score < CONTEXT_MIN) v = v.withIssue("Could not line this box up with the template; check the value")
            Triple(f, v, score)
        }
        reads.forEach { (f, _, score) -> diagnostics[f.title] = "context %.2f".format(score) }
        lap("fields")
        // Summed over the threads: CPU time, more than the wall time of "fields".
        timings["fields_context"] = contextNs.get() / 1_000_000
        timings["fields_read"] = readNs.get() / 1_000_000
        timings["total"] = (System.nanoTime() - clock) / 1_000_000
        timings["inliers"] = fit.inliers.toLong()
        return assemble(reads.map { it.first to it.second }, imagePath, timings).copy(diagnostics = diagnostics)
    }

    /**
     * Of the global and regional homographies, the one under which the
     * printed surroundings of [box] (labels, cell borders; the handwriting
     * inside is masked out) best correlate with the reference image.
     */
    private fun bestHomography(photo: Mat, reference: Mat, fit: Aligner.Fit, box: Box): Pair<Mat, Double> {
        // Box ~48 px tall, but the whole patch at most ~256 px wide: a text
        // line across the page needs no more detail than that to be lined up.
        val span = 1 + 2 * CONTEXT_MARGIN
        val scale = minOf(48.0 / max(box.h, 1.0), 256.0 / max(span * box.w, 1.0)).coerceIn(0.2, 3.0)
        val sigma = max(1.5, 6.0 * scale * box.h / 48.0)
        val (ref, mask) = refContext.computeIfAbsent(System.identityHashCode(reference) to box) {
            val (r, rb) = CellFinder.warpPatch(reference, identity(), box, scale, CONTEXT_MARGIN)
            val m = Mat(r.size(), CvType.CV_8U, Scalar(255.0))
            Imgproc.rectangle(m, Point(rb.x0, rb.y0), Point(rb.x1, rb.y1), Scalar(0.0), -1)
            r to m
        }
        return fit.candidates(Point((box.x0 + box.x1) / 2, (box.y0 + box.y1) / 2)).map { h ->
            val (p, _) = CellFinder.warpPatch(photo, h, box, scale, CONTEXT_MARGIN)
            h to correlation(ref, p, mask, sigma).also { p.release() }
        }.maxBy { it.second }
    }

    /** The reference side of the context check, per (reference image, box): the same on every scan. */
    private val refContext = ConcurrentHashMap<Pair<Int, Box>, Pair<Mat, Mat>>()

    private fun correlation(a: Mat, b: Mat, mask: Mat, sigma: Double): Double {
        val fa = Mat(); val fb = Mat()
        a.convertTo(fa, CvType.CV_32F); b.convertTo(fb, CvType.CV_32F)
        // Wide enough to forgive a few pixels of residual on thin printed
        // lines, far narrower than the one-row shift this check must catch.
        Imgproc.GaussianBlur(fa, fa, Size(0.0, 0.0), sigma)
        Imgproc.GaussianBlur(fb, fb, Size(0.0, 0.0), sigma)
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

    private fun readField(photo: Mat, h: Mat, box: Box, f: TemplateField, t: SheetTemplate, rw: Double, rh: Double): ExtractedField {
        if (!inside(photo, h, box)) {
            return ExtractedField("", 0.0, issue = "Cut off in the photo")
        }
        val (patch, pb) = CellFinder.warpPatch(photo, h, box, scaleFor(box), 0.5)
        try {
            if (f.kind == FieldKind.CHOICE) return readChoice(photo, h, f, box, rw, rh)
            if (f.kind == FieldKind.TEXT && f.cells <= 1) {
                // Words, names, codes: the printed-text model reads whole
                // words far better than the digit/letter box model.
                val area = if (f.free) pb else CellFinder.findCell(patch, pb)?.inset(0.04, 2.0) ?: pb
                val crop = CellFinder.crop(patch, area) ?: return ExtractedField("", 0.0, issue = "Box not found")
                if (CellFinder.looksBlank(crop)) return ExtractedField("", BLANK_CONFIDENCE, crop = png(crop))
                val whole = listOf(Box(0.0, 0.0, crop.cols().toDouble(), crop.rows().toDouble()))
                fun clean(t: String) = t.trim().trimStart(':', '.', '-', ' ').trim()
                var (raw, conf) = wordReader().recognize(crop, whole).first()
                // The handwriting model saw nothing in an inked box: a second
                // opinion from the printed-text model (short block capitals).
                if (clean(raw).isEmpty() && handwriting != null) textReader().recognize(crop, whole).first().let { raw = it.first; conf = it.second }
                val value = clean(raw)
                // Ink, yet nothing read: the writing was missed, not absent
                // (an empty box is caught by looksBlank above).
                if (value.isEmpty()) return ExtractedField("", 0.0, rawText = raw, crop = png(crop),
                    issue = "Could not read the writing here; type it in")
                return ExtractedField(value, conf, rawText = raw, crop = png(crop))
            }
            val text = f.kind == FieldKind.REGISTRATION || f.kind == FieldKind.TEXT
            val combCells = if (f.kind == FieldKind.REGISTRATION) t.registrationLength ?: f.cells else f.cells
            if (combCells > 1) {
                val mask = if (f.kind == FieldKind.REGISTRATION) t.registrationMask
                    else if (text) null else "D".repeat(combCells)
                CellFinder.findComb(patch, pb, combCells)?.let { return readComb(patch, it, mask, if (text) regModel else model) }
            }
            val cell = CellFinder.findCell(patch, pb)
            val area = cell?.inset(0.05, 2.0) ?: pb
            val crop = CellFinder.crop(patch, area) ?: return ExtractedField("", 0.0, issue = "Box not found")
            if (cell != null && CellFinder.looksBlank(crop)) return ExtractedField("", BLANK_CONFIDENCE, crop = png(crop))
            val allowed = if (text) CHARSET else DIGITS
            val r = readVoted(if (text) regModel else model, listOf(crop), listOf(allowed)).first()
            return ExtractedField(
                r.text, r.confidence, rawText = r.text, crop = png(crop),
                issue = if (cell == null) "Could not find the printed box; check the value" else null,
            )
        } finally {
            patch.release()
        }
    }

    /**
     * Which printed option is ticked. Finds the tick itself: the strongest ink
     * just above the printed options (printed letters never reach there),
     * and takes the option under its centre. Confident only when that centre
     * is well inside one option; a tick between two options, or two ticks,
     * goes to review. No ink at all is a confident blank.
     */
    private fun readChoice(photo: Mat, h: Mat, f: TemplateField, field: Box, rw: Double, rh: Double): ExtractedField {
        if (f.options.isEmpty() || f.options.size != f.optionBoxes.size) return ExtractedField("", 0.0, issue = "No options set")
        val scale = scaleFor(field)
        val (patch, pb) = CellFinder.warpPatch(photo, h, field, scale, 1.2)
        try {
            fun px(x: Double) = (x - field.x0) * scale + pb.x0
            fun py(y: Double) = (y - field.y0) * scale + pb.y0
            val opts = f.optionBoxes.map { nb -> Box(px(nb.left * rw), py(nb.top * rh), px(nb.right * rw), py(nb.bottom * rh)) }
            val oh = opts.maxOf { it.h }
            val top = opts.minOf { it.y0 }
            val band = Box(opts.first().x0 - 0.3 * oh, top - 0.55 * oh, opts.last().x1 + 0.3 * oh, top + 0.2 * oh)
            val crop = CellFinder.crop(patch, band) ?: return ExtractedField("", 0.0, issue = "Cut off in the photo")
            val ink = CellFinder.ink(crop)
            // The tick's low point (its vertex, nearest the option it marks)
            // is in the lower half of the band; its long arm sweeps up and
            // away, so the upper half would point at the wrong option.
            val lower = ink.submat(Rect(0, ink.rows() / 2, ink.cols(), ink.rows() - ink.rows() / 2))
            val col = Mat()
            org.opencv.core.Core.reduce(lower, col, 0, org.opencv.core.Core.REDUCE_SUM, CvType.CV_64F)
            val v = DoubleArray(col.cols()).also { col.get(0, 0, it) }.map { it / 255.0 }
            val total = org.opencv.core.Core.countNonZero(ink).toDouble()
            ink.release(); col.release()
            val win = max(3, (0.5 * oh).toInt())
            val sums = (0..max(0, v.size - win)).map { i -> (i until min(v.size, i + win)).sumOf { v[it] } }
            val bi = sums.indices.maxByOrNull { sums[it] } ?: 0
            val best = sums.getOrElse(bi) { 0.0 }
            val noise = sums.sorted().getOrElse(sums.size / 2) { 0.0 }
            val crops = CellFinder.crop(patch, Box(band.x0, band.y0, band.x1, opts.maxOf { it.y1 } + 0.2 * oh))?.let(::png)
            // A tick is a thin stroke: a few pixels per column over a short run.
            if (total < 3.0 * win || best < max(1.5 * win, 3 * noise)) {
                return ExtractedField("", 0.9, rawText = "no mark", crop = crops)
            }
            val cx = band.x0 + bi + win / 2.0
            val k = opts.indices.minByOrNull { i -> val o = opts[i]; if (cx in o.x0..o.x1) 0.0 else min(abs(cx - o.x0), abs(cx - o.x1)) }!!
            val o = opts[k]
            val inside = cx > o.x0 + 0.15 * o.w && cx < o.x1 - 0.15 * o.w
            // A second, similar mark elsewhere means two ticks or a stray stroke.
            val far = sums.indices.filter { abs(it - bi) > 1.5 * win }.maxOfOrNull { sums[it] } ?: 0.0
            val clear = inside && far < 0.5 * best
            return ExtractedField(f.options[k], if (clear) 0.95 else 0.6,
                rawText = "mark at %.0f%% of options".format(100 * (cx - opts.first().x0) / max(1.0, opts.last().x1 - opts.first().x0)),
                crop = crops)
        } finally {
            patch.release()
        }
    }

    /**
     * One character per printed box, each from the class its position allows.
     * Reading box by box (borders trimmed) beat reading the comb as one strip
     * on the sample sheets: as a strip, CTC merges the "66" of adjacent boxes.
     */
    private fun readComb(patch: Mat, cells: List<Box>, mask: String?, model: FieldModel): ExtractedField {
        val text = StringBuilder()
        val alt = StringBuilder()
        var hasAlt = false
        var confidence = 1.0
        // An unfilled box (e.g. only "23" written): no character, no model run.
        val written = cells.withIndex().mapNotNull { (i, c) ->
            CellFinder.crop(patch, c.inset(0.06, 1.0))?.takeUnless { CellFinder.looksBlank(it) }?.let { i to it }
        }
        // All boxes of the comb in one model call.
        val reads = readVoted(model, written.map { it.second }, written.map { CtcDecoder.allowedFor(mask?.getOrNull(it.first)) })
        for ((k, w) in written.withIndex()) {
            val i = w.first
            val maskChar = mask?.getOrNull(i)
            val r = reads[k]
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

    /**
     * Reads each crop as it is and under three small changes (4% tighter, 4%
     * looser, shifted 1 px), all in one model call, and takes the majority
     * reading. Its confidence is the least certain agreeing read times the
     * share that agree: a reading a 1-pixel shift changes was never certain.
     * On 5,000 held-out synthetic crops (v6 models) this cut trusted-but-wrong
     * readings by about half at the same accuracy (docs/PROGRESS.md).
     */
    private fun readVoted(model: FieldModel, crops: List<Mat>, allowed: List<String>): List<Reading> {
        if (crops.isEmpty()) return emptyList()
        if (!augment) return model.runAll(crops).mapIndexed { i, p -> CtcDecoder.decode(p, allowed[i]) }
        val variants = crops.map(::variants)
        val probs = model.runAll(variants.flatten())
        val check = checkModel?.runAll(crops)
        var k = 0
        return variants.mapIndexed { i, vs ->
            val reads = vs.map { CtcDecoder.decode(probs[k++], allowed[i]) }
            vs.drop(1).forEach { it.release() }
            val r = vote(reads)
            // Two models trained apart rarely make the same mistake: v6
            // alone read a "52" as "5" at 0.90 on a synthetic sheet, v5 read 52.
            if (check != null && CtcDecoder.decode(check[i], allowed[i]).text != r.text) r.copy(confidence = min(r.confidence, DISAGREE_CONFIDENCE))
            else r
        }
    }

    private fun assemble(reads: List<Pair<TemplateField, ExtractedField>>, imagePath: String?, timings: Map<String, Long>): ScanResult {
        fun of(kind: FieldKind) = reads.firstOrNull { it.first.kind == kind }?.second ?: ExtractedField.NOT_ON_SHEET
        return ScanResult(
            registrationNo = of(FieldKind.REGISTRATION),
            partA = of(FieldKind.PART_A),
            partB = of(FieldKind.PART_B),
            questions = reads.filter { it.first.kind == FieldKind.QUESTION }
                .map { (f, v) -> LabelledMark(f.label.ifEmpty { "Question" }, f.part, v, f.maxMarks) },
            writtenTotals = reads.filter { it.first.kind == FieldKind.WRITTEN_TOTAL }
                .map { (f, v) -> LabelledMark(f.title, "", v) },
            extras = reads.filter { it.first.kind == FieldKind.MARK || it.first.kind == FieldKind.TEXT || it.first.kind == FieldKind.CHOICE }
                .map { (f, v) -> LabelledMark(f.title, "", v, f.maxMarks, blocking = f.kind == FieldKind.MARK) },
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
        /** Ceiling on a reading the check model disagrees with: review. */
        const val DISAGREE_CONFIDENCE = 0.5

        /** An empty cell (no stroke at all) is a confident blank. */
        const val BLANK_CONFIDENCE = 0.97

        /** Context around a field compared with the reference, in box sizes. */
        const val CONTEXT_MARGIN = 1.0

        /** Below this context correlation the field is flagged as possibly misaligned. */
        const val CONTEXT_MIN = 0.5

        /** Longer side of a stored reference image. */
        const val REFERENCE_SIDE = 1600

        /** Patch scale giving a field ~96 px tall: plenty for a 32 px model input. */
        fun scaleFor(b: Box) = (96.0 / max(b.h, 1.0)).coerceIn(1.0, 6.0)

        fun identity(): Mat = Mat.eye(3, 3, CvType.CV_64F)

        /** The crop itself, then 4% tighter, 4% looser (edge pixels repeated), 1 px to the right. */
        fun variants(g: Mat): List<Mat> {
            val h = g.rows(); val w = g.cols()
            val dy = max(1, Math.round(0.04 * h).toInt()); val dx = max(1, Math.round(0.04 * w).toInt())
            val out = arrayListOf(g)
            if (h > 2 * dy + 4 && w > 2 * dx + 4) out += g.submat(dy, h - dy, dx, w - dx)
            out += Mat().also { Core.copyMakeBorder(g, it, dy, dy, dx, dx, Core.BORDER_REPLICATE) }
            // Wrap-around shift by one column, as numpy's roll in the evaluation.
            out += Mat().also { m ->
                if (w < 2) g.copyTo(m)
                else Core.hconcat(listOf(g.colRange(w - 1, w), g.colRange(0, w - 1)), m)
            }
            return out
        }

        /** Majority text (ties: the unchanged crop's, if tied); confidence as in [readVoted]. */
        fun vote(reads: List<Reading>): Reading {
            val counts = reads.groupingBy { it.text }.eachCount()
            val top = counts.values.max()
            val text = if (counts[reads[0].text] == top) reads[0].text else counts.entries.first { it.value == top }.key
            val agree = reads.filter { it.text == text }
            return Reading(text, agree.minOf { it.confidence } * agree.size / reads.size)
        }

        /**
         * Field threads for this machine: one per core up to 4. Each model
         * call then runs single-threaded, which for a model this small
         * beats splitting one call over cores.
         */
        fun defaultThreads() = Runtime.getRuntime().availableProcessors().coerceIn(1, 4)

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
