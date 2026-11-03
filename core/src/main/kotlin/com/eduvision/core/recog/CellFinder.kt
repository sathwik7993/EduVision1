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
