package com.eduvision.core.recog

import org.opencv.calib3d.Calib3d
import org.opencv.core.Core
import org.opencv.core.Mat
import org.opencv.core.MatOfDMatch
import org.opencv.core.MatOfKeyPoint
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Point
import org.opencv.core.Size
import org.opencv.features2d.DescriptorMatcher
import org.opencv.features2d.ORB
import org.opencv.imgproc.Imgproc
import kotlin.math.hypot
import kotlin.math.max

/**
 * Registers a photo onto a template's reference image by matching ORB
 * features: ~40 ms on a desktop, no text recognition, rotation and
 * perspective tolerant, and works on photos that cut off the page edges.
 *
 * Paper bends and different print runs of the same booklet move parts of the
 * page relative to each other (on the sample photos the marks slip of one
 * print sits a full row higher), so besides the global homography each field
 * can get a regional one fitted to the matches around it.
 */
class Aligner(reference: Mat) {
    /** Reference pixels -> working (downscaled) reference pixels. */
    private val refScale: Double
    private val refShape: Size
    private val refPts: Array<Point>
    private val refDesc: Mat

    init {
        val small = downscale(reference, WORK_SIDE)
        refScale = small.cols().toDouble() / reference.cols()
        refShape = small.size()
        val kp = MatOfKeyPoint()
        refDesc = Mat()
        orb().detectAndCompute(small, Mat(), kp, refDesc)
        refPts = kp.toArray().map { Point(it.pt.x / refScale, it.pt.y / refScale) }.toTypedArray()
        small.release()
    }

    /** Matches in reference pixels (src) and photo pixels (dst). */
    class Fit internal constructor(
        val global: Mat,
        val inliers: Int,
        private val src: Array<Point>,
        private val dst: Array<Point>,
        private val tol: Double,
        private val refSide: Double,
    ) {
        /**
         * A homography fitted to the matches within [radius] (fraction of the
         * reference's longer side) of [center], used when it explains clearly
         * more of those matches than the global one does.
         */
        fun regional(center: Point, radius: Double = 0.3): Mat = fitNear(center, radius)?.takeIf { (h, s, d) ->
            countWithin(h, s, d) > 1.2 * countWithin(global, s, d)
        }?.first ?: global

        /**
         * The global homography plus regional ones at two radii: the caller
         * picks whichever makes the printed context around a field match.
         */
        fun candidates(center: Point): List<Mat> {
            // Neighbouring fields (a row of marks cells) share their regional
            // fits: one fit per patch of page, not one per field.
            val cell = 0.06 * refSide
            val key = Math.round(center.x / cell) * 10_000 + Math.round(center.y / cell)
            return cache.computeIfAbsent(key) {
                val c = Point((Math.round(center.x / cell)) * cell, (Math.round(center.y / cell)) * cell)
                listOf(global) + listOf(0.3, 0.15).mapNotNull { fitNear(c, it)?.first }
            }
        }

        /** Shared by the threads reading the fields of one sheet. */
        private val cache = java.util.concurrent.ConcurrentHashMap<Long, List<Mat>>()

        private fun fitNear(center: Point, radius: Double): Triple<Mat, MatOfPoint2f, MatOfPoint2f>? {
            val r = radius * refSide
            val idx = src.indices.filter { hypot(src[it].x - center.x, src[it].y - center.y) < r }
            if (idx.size < 15) return null
            val s = MatOfPoint2f(*idx.map { src[it] }.toTypedArray())
            val d = MatOfPoint2f(*idx.map { dst[it] }.toTypedArray())
            val mask = Mat()
            val h = Calib3d.findHomography(s, d, Calib3d.RANSAC, tol, mask)
            if (h.empty() || Core.countNonZero(mask) < 12) return null
            return Triple(h, s, d)
        }

        private fun countWithin(h: Mat, s: MatOfPoint2f, d: MatOfPoint2f): Int {
            val p = MatOfPoint2f()
            Core.perspectiveTransform(s, p, h)
            val a = p.toArray()
            val b = d.toArray()
            return a.indices.count { hypot(a[it].x - b[it].x, a[it].y - b[it].y) < tol }
        }
    }

    /** Null when the photo does not show this layout. */
    fun fit(photo: Mat): Fit? {
        val small = downscale(photo, WORK_SIDE)
        val s = small.cols().toDouble() / photo.cols()
        val kp = MatOfKeyPoint()
        val desc = Mat()
        orb().detectAndCompute(small, Mat(), kp, desc)
        small.release()
        if (desc.empty() || refDesc.empty()) return null
        val pts = kp.toArray()
        val knn = ArrayList<MatOfDMatch>()
        DescriptorMatcher.create(DescriptorMatcher.BRUTEFORCE_HAMMING).knnMatch(refDesc, desc, knn, 2)
        val good = knn.mapNotNull { m ->
            val a = m.toArray()
            if (a.size == 2 && a[0].distance < 0.8f * a[1].distance) a[0] else null
        }
        if (good.size < MIN_INLIERS) return null
        val src = good.map { refPts[it.queryIdx] }.toTypedArray()
        val dst = good.map { val p = pts[it.trainIdx].pt; Point(p.x / s, p.y / s) }.toTypedArray()
        val tol = 4.0 / s
        val mask = Mat()
        val h = Calib3d.findHomography(MatOfPoint2f(*src), MatOfPoint2f(*dst), Calib3d.RANSAC, tol, mask)
        if (h.empty()) return null
        val inliers = Core.countNonZero(mask)
        if (inliers < MIN_INLIERS || !plausible(h, photo.size())) return null
        // All ratio-test matches, not just the global inliers: the matches of
        // a part of the page that moved are exactly the global outliers.
        return Fit(h, inliers, src, dst, tol, max(refShape.width, refShape.height) / refScale)
    }

    /** Rejects degenerate fits: the page must map to a sane, non-flipped quad. */
    private fun plausible(h: Mat, photo: Size): Boolean {
        val w = refShape.width / refScale
        val hh = refShape.height / refScale
        val q = MatOfPoint2f(Point(0.0, 0.0), Point(w, 0.0), Point(w, hh), Point(0.0, hh))
        val out = MatOfPoint2f()
        Core.perspectiveTransform(q, out, h)
        val c = out.toArray()
        var area = 0.0
        for (i in 0 until 4) area += c[i].x * c[(i + 1) % 4].y - c[(i + 1) % 4].x * c[i].y
        area /= 2
        val photoArea = photo.width * photo.height
        return area > 0.05 * photoArea && area < 25 * photoArea
    }

    companion object {
        const val WORK_SIDE = 1000
        const val MIN_INLIERS = 25

        private fun orb() = ORB.create(3000)

        fun downscale(m: Mat, side: Int): Mat {
            val s = side.toDouble() / max(m.cols(), m.rows())
            val out = Mat()
            if (s >= 1) m.copyTo(out) else Imgproc.resize(m, out, Size(), s, s, Imgproc.INTER_AREA)
            return out
        }
    }
}
