package com.eduvision.core.recog

import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.Rect
import org.opencv.core.Scalar
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Axis-aligned box in patch pixels. */
data class Box(val x0: Double, val y0: Double, val x1: Double, val y1: Double) {
    val w get() = x1 - x0
    val h get() = y1 - y0
    fun inset(fraction: Double, px: Double): Box {
        val dx = w * fraction + px
        val dy = h * fraction + px
        return Box(x0 + dx, y0 + dy, x1 - dx, y1 - dy)
    }
    fun iou(o: Box): Double {
        val ix = max(0.0, min(x1, o.x1) - max(x0, o.x0))
        val iy = max(0.0, min(y1, o.y1) - max(y0, o.y0))
        val i = ix * iy
        return i / (w * h + o.w * o.h - i)
    }
}

/**
 * Finds the printed box a handwritten value sits in, so the model sees the
 * inside of the cell only: no printed label, no cell border, whatever the
 * alignment residual. Works on an axis-aligned patch around the expected box
 * (see [warpPatch]).
 */
object CellFinder {
    /**
     * Cuts the reference-frame region around [box] (reference pixels) out of
     * [photo], rectified: patch pixel p is reference pixel origin + p / scale.
     * Returns the patch and [box] in patch pixels.
     */
    fun warpPatch(photo: Mat, refToPhoto: Mat, box: Box, scale: Double, margin: Double): Pair<Mat, Box> {
        val mx = box.w * margin
        val my = box.h * margin
        val ox = box.x0 - mx
        val oy = box.y0 - my
        val a = Mat(3, 3, CvType.CV_64F)
        a.put(0, 0, 1 / scale, 0.0, ox, 0.0, 1 / scale, oy, 0.0, 0.0, 1.0)
        val m = Mat()
        Core.gemm(refToPhoto, a, 1.0, Mat(), 0.0, m)
        val size = Size(((box.w + 2 * mx) * scale).roundToInt().toDouble(), ((box.h + 2 * my) * scale).roundToInt().toDouble())
        val out = Mat()
        Imgproc.warpPerspective(photo, out, m, size, Imgproc.INTER_LINEAR or Imgproc.WARP_INVERSE_MAP,
            Core.BORDER_CONSTANT, Scalar(255.0))
        return out to Box(mx * scale, my * scale, (mx + box.w) * scale, (my + box.h) * scale)
    }

    /** Dark strokes as 255 on 0. */
    fun ink(patch: Mat): Mat {
        val th = Mat()
        Imgproc.adaptiveThreshold(patch, th, 255.0, Imgproc.ADAPTIVE_THRESH_MEAN_C, Imgproc.THRESH_BINARY_INV, 31, 12.0)
        return th
    }

    private fun open(src: Mat, w: Int, h: Int): Mat {
        val out = Mat()
        Imgproc.morphologyEx(src, out, Imgproc.MORPH_OPEN,
            Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(max(1, w).toDouble(), max(1, h).toDouble())))
        return out
    }

    /**
     * The enclosed table cell that best overlaps [expected], or null when the
     * box has no printed border nearby (the caller then flags the field: a
     * value read from a guessed position must not be trusted).
     */
    fun findCell(patch: Mat, expected: Box): Box? {
        val th = ink(patch)
        val v = open(th, 1, max(3, (0.4 * expected.h).toInt()))
        val h = open(th, max(3, (0.4 * expected.w).toInt()), 1)
        val lines = Mat()
        Core.bitwise_or(v, h, lines)
        Imgproc.dilate(lines, lines, Mat.ones(3, 3, CvType.CV_8U))
        val free = Mat()
        Core.bitwise_not(lines, free)
        val labels = Mat()
        val stats = Mat()
        val cents = Mat()
        val n = Imgproc.connectedComponentsWithStats(free, labels, stats, cents, 4)
        var best: Box? = null
        var bestIou = 0.25
        for (i in 1 until n) {
            val x = stats.get(i, Imgproc.CC_STAT_LEFT)[0]
            val y = stats.get(i, Imgproc.CC_STAT_TOP)[0]
            val w = stats.get(i, Imgproc.CC_STAT_WIDTH)[0]
            val hh = stats.get(i, Imgproc.CC_STAT_HEIGHT)[0]
            val area = stats.get(i, Imgproc.CC_STAT_AREA)[0]
            if (x <= 0 || y <= 0 || x + w >= patch.cols() || y + hh >= patch.rows()) continue
            if (w < 0.4 * expected.w || hh < 0.4 * expected.h || w > 2.2 * expected.w || hh > 2.2 * expected.h) continue
            if (area < 0.6 * w * hh) continue
            val b = Box(x, y, x + w, y + hh)
            val iou = b.iou(expected)
            if (iou > bestIou) { bestIou = iou; best = b }
        }
        listOf(th, v, h, lines, free, labels, stats, cents).forEach { it.release() }
        return best
    }

    /**
     * A row of [cells] equal printed boxes (a registration-number comb):
     * finds the strip's top, bottom, left and right borders, then each
     * separator near its expected position. Only lines spanning the whole
     * strip height count, so handwritten "1"s and "H"s are not separators.
     * Returns the cell boxes, or null when the strip borders are not found.
     */
    fun findComb(patch: Mat, expected: Box, cells: Int): List<Box>? {
        val th = ink(patch)
        val hz = open(th, max(3, (0.5 * min(expected.w, 3 * expected.h)).toInt()), 1)
        val rows = peaks(profile(hz, byRow = true), 0.35 * min(expected.w, 3 * expected.h))
        val top = nearest(rows, expected.y0, 0.45 * expected.h)
        val bottom = nearest(rows, expected.y1, 0.45 * expected.h)
        if (top == null || bottom == null || bottom - top < 0.4 * expected.h) {
            th.release(); hz.release(); return null
        }
        val strip = th.submat(Rect(0, top.toInt(), th.cols(), (bottom - top).toInt().coerceAtLeast(1)))
        val sh = bottom - top
        val v = open(strip, 1, max(3, (0.8 * sh).toInt()))
        val cols = peaks(profile(v, byRow = false), 0.8 * sh)
        val tol = 0.35 * min(expected.w, 1.5 * expected.h)
        val left = nearest(cols, expected.x0, tol)
        val right = nearest(cols, expected.x1, tol)
        th.release(); hz.release(); v.release()
        if (left == null || right == null || right - left < 0.5 * expected.w) return null
        val pitch = (right - left) / cells
        val xs = buildList {
            add(left)
            for (i in 1 until cells) {
                val e = left + i * pitch
                add(nearest(cols, e, 0.25 * pitch) ?: e)
            }
            add(right)
        }
        return (0 until cells).map { Box(xs[it], top, xs[it + 1], bottom) }
    }

    /**
     * How many equal printed boxes the strip around [expected] has, from the
     * separators that span its full height; 0 when it does not look like a
     * comb (a single box, or unevenly spaced lines).
     */
    fun countCombCells(patch: Mat, expected: Box): Int {
        val th = ink(patch)
        val hz = open(th, max(3, (0.5 * min(expected.w, 3 * expected.h)).toInt()), 1)
        val rows = peaks(profile(hz, byRow = true), 0.35 * min(expected.w, 3 * expected.h))
        val top = nearest(rows, expected.y0, 0.45 * expected.h)
        val bottom = nearest(rows, expected.y1, 0.45 * expected.h)
        hz.release()
        if (top == null || bottom == null || bottom - top < 0.4 * expected.h) { th.release(); return 0 }
        val sh = bottom - top
        val strip = th.submat(Rect(0, top.toInt(), th.cols(), sh.toInt().coerceAtLeast(1)))
        val v = open(strip, 1, max(3, (0.8 * sh).toInt()))
        val cols = peaks(profile(v, byRow = false), 0.8 * sh)
            .filter { it > expected.x0 - 0.3 * sh && it < expected.x1 + 0.3 * sh }
        th.release(); v.release()
        if (cols.size < 5) return 0
        val gaps = cols.zipWithNext { a, b -> b - a }
        val median = gaps.sorted()[gaps.size / 2]
        // Merge a doubled line; reject combs with uneven boxes.
        val cells = gaps.sumOf { (it / median).let { r -> if (r < 0.5) 0 else r.roundToInt() } }
        val even = gaps.all { it < 0.5 * median || abs(it / median - (it / median).roundToInt()) < 0.25 }
        return if (even && cells in 4..16) cells else 0
    }

    /**
     * What the teacher tapped at [x],[y] on a reference image: the printed box
     * enclosing that point, and, when that box is one of a row of equal boxes
     * (a registration-number comb, or a marks-table row), the whole row and
     * its box count. Null when the point is not inside an enclosed box
     * (writing on a line): the teacher then draws the box instead.
     */
    data class Picked(val cell: Box, val row: Box?, val rowCells: Int)

    /** Printed rules (dilated), 255 on 0, from an ink mask; [k] = minimum rule length. */
    internal fun ruleMask(th: Mat, k: Int): Mat {
        // Photos are slightly rotated: thicken across the line direction first
        // so a tilted rule survives the straight-line opening.
        val thx = Mat(); val thy = Mat()
        Imgproc.dilate(th, thx, Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(3.0, 1.0)))
        Imgproc.dilate(th, thy, Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(1.0, 3.0)))
        val hz = open(thy, k, 1)
        val v = printedVerticals(open(thx, 1, k / 2), hz)
        thx.release(); thy.release()
        val lines = Mat()
        Core.bitwise_or(v, hz, lines)
        Imgproc.dilate(lines, lines, Mat.ones(3, 3, CvType.CV_8U))
        v.release(); hz.release()
        return lines
    }


    /**
     * Keeps the vertical strokes that run from one printed horizontal rule to
     * another: box dividers do, a handwritten "1" or the legs of an "H" do not.
     */
    private fun printedVerticals(v: Mat, hz: Mat): Mat {
        val near = Mat()
        Imgproc.dilate(hz, near, Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(7.0, 9.0)))
        val labels = Mat(); val stats = Mat(); val cents = Mat()
        val n = Imgproc.connectedComponentsWithStats(v, labels, stats, cents, 8)
        val out = Mat.zeros(v.size(), CvType.CV_8U)
        for (i in 1 until n) {
            val x = stats.get(i, Imgproc.CC_STAT_LEFT)[0].toInt(); val y = stats.get(i, Imgproc.CC_STAT_TOP)[0].toInt()
            val w = stats.get(i, Imgproc.CC_STAT_WIDTH)[0].toInt(); val h = stats.get(i, Imgproc.CC_STAT_HEIGHT)[0].toInt()
            fun touches(row: Int) = row in 0 until near.rows() &&
                Core.countNonZero(near.submat(Rect(x, row, w, 1))) > 0
            // A rule cut by the edge of the search window continues beyond it.
            if ((y <= 1 || touches(y)) && (y + h >= near.rows() - 1 || touches(y + h - 1))) {
                val mask = Mat()
                Core.compare(labels, org.opencv.core.Scalar(i.toDouble()), mask, Core.CMP_EQ)
                out.setTo(org.opencv.core.Scalar(255.0), mask)
                mask.release()
            }
        }
        listOf(near, labels, stats, cents).forEach { it.release() }
        return out
    }

    fun boxAt(page: Mat, x: Double, y: Double): Picked? {
        val w = page.cols(); val h = page.rows()
        // Wide enough for a whole registration comb starting at the tap.
        val wx0 = (x - 0.55 * w).toInt().coerceIn(0, w - 1)
        val wx1 = (x + 0.55 * w).toInt().coerceIn(wx0 + 1, w)
        val wy0 = (y - 0.1 * h).toInt().coerceIn(0, h - 1)
        val wy1 = (y + 0.1 * h).toInt().coerceIn(wy0 + 1, h)
        val win = page.submat(Rect(wx0, wy0, wx1 - wx0, wy1 - wy0))
        val th = ink(win)
        // Printed rules are long and straight; handwriting strokes are short.
        val k = max(12, (0.03 * w).toInt())
        val lines = ruleMask(th, k)
        val free = Mat()
        Core.bitwise_not(lines, free)
        val labels = Mat(); val stats = Mat(); val cents = Mat()
        val n = Imgproc.connectedComponentsWithStats(free, labels, stats, cents, 4)
        val px = (x - wx0).toInt().coerceIn(0, win.cols() - 1)
        val py = (y - wy0).toInt().coerceIn(0, win.rows() - 1)
        // A tap on a rule picks the nearest box around it.
        var id = labels.get(py, px)[0].toInt()
        var r = 2
        while (id == 0 && r <= 16) {
            id = listOf(-r to 0, r to 0, 0 to -r, 0 to r).map { (dx, dy) ->
                labels.get((py + dy).coerceIn(0, win.rows() - 1), (px + dx).coerceIn(0, win.cols() - 1))[0].toInt()
            }.firstOrNull { it > 0 } ?: 0
            r += 2
        }
        fun boxOf(i: Int): Box? {
            val bx = stats.get(i, Imgproc.CC_STAT_LEFT)[0]; val by = stats.get(i, Imgproc.CC_STAT_TOP)[0]
            val bw = stats.get(i, Imgproc.CC_STAT_WIDTH)[0]; val bh = stats.get(i, Imgproc.CC_STAT_HEIGHT)[0]
            val area = stats.get(i, Imgproc.CC_STAT_AREA)[0]
            // Enclosed: does not touch the search window, and fills its bounding box.
            if (bx <= 0 || by <= 0 || bx + bw >= win.cols() || by + bh >= win.rows()) return null
            if (bw < 8 || bh < 8 || area < 0.6 * bw * bh) return null
            return Box(bx + wx0, by + wy0, bx + bw + wx0, by + bh + wy0)
        }
        val cell = if (id > 0) boxOf(id) else null
        var picked: Picked? = null
        if (cell != null) {
            // Neighbours of the same size on the same row, touching across one rule.
            val boxes = (1 until n).filter { it != id }.mapNotNull(::boxOf)
            val gap = 0.25 * cell.h + 6
            fun next(from: Box, dir: Int) = boxes.firstOrNull { b ->
                abs(b.y0 - from.y0) < 0.2 * from.h && abs(b.h - from.h) < 0.2 * from.h &&
                    abs(b.w - cell.w) < 0.3 * cell.w &&
                    (if (dir > 0) b.x0 - from.x1 else from.x0 - b.x1) in -2.0..gap
            }
            val row = mutableListOf(cell)
            while (true) row.add(next(row.last(), 1) ?: break)
            while (true) row.add(0, next(row.first(), -1) ?: break)
            picked = if (row.size >= 3) Picked(cell, Box(row.first().x0, row.minOf { it.y0 }, row.last().x1, row.maxOf { it.y1 }), row.size)
            else Picked(cell, null, 1)
        }
        listOf(th, lines, free, labels, stats, cents).forEach { it.release() }
        return picked
    }

    private fun profile(m: Mat, byRow: Boolean): DoubleArray {
        val r = Mat()
        Core.reduce(m, r, if (byRow) 1 else 0, Core.REDUCE_SUM, CvType.CV_64F)
        val out = DoubleArray(r.total().toInt())
        r.get(0, 0, out)
        r.release()
        for (i in out.indices) out[i] /= 255.0
        return out
    }

    /** Centres of the runs above [threshold]. */
    private fun peaks(p: DoubleArray, threshold: Double): List<Double> {
        val out = ArrayList<Double>()
        var i = 0
        while (i < p.size) {
            if (p[i] > threshold) {
                var j = i
                while (j < p.size && p[j] > threshold) j++
                out += (i + j - 1) / 2.0
                i = j
            } else i++
        }
        return out
    }

    private fun nearest(ps: List<Double>, target: Double, tol: Double) =
        ps.filter { abs(it - target) <= tol }.minByOrNull { abs(it - target) }

    /**
     * No writing in [crop]: no ink stroke at least a quarter of its height.
     * Dots and specks (stray marks) do not count. Lets the reader skip the
     * model for the many empty cells of a marks table.
     */
    fun looksBlank(crop: Mat): Boolean {
        val th = ink(crop)
        val labels = Mat(); val stats = Mat(); val cents = Mat()
        val n = Imgproc.connectedComponentsWithStats(th, labels, stats, cents, 8)
        val minH = 0.25 * crop.rows()
        val minArea = max(6.0, 0.002 * crop.total())
        var blank = true
        for (i in 1 until n) {
            if (stats.get(i, Imgproc.CC_STAT_HEIGHT)[0] >= minH && stats.get(i, Imgproc.CC_STAT_AREA)[0] >= minArea) { blank = false; break }
        }
        listOf(th, labels, stats, cents).forEach { it.release() }
        return blank
    }

    /** The pixels inside [b], clipped to the patch; null when nothing is left. */
    fun crop(patch: Mat, b: Box): Mat? {
        val x0 = b.x0.roundToInt().coerceIn(0, patch.cols())
        val y0 = b.y0.roundToInt().coerceIn(0, patch.rows())
        val x1 = b.x1.roundToInt().coerceIn(0, patch.cols())
        val y1 = b.y1.roundToInt().coerceIn(0, patch.rows())
        if (x1 - x0 < 4 || y1 - y0 < 4) return null
        return patch.submat(Rect(x0, y0, x1 - x0, y1 - y0))
    }
}
