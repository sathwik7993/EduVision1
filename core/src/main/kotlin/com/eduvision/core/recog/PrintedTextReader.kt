package com.eduvision.core.recog

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfPoint
import org.opencv.core.Rect
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import java.nio.FloatBuffer
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** One line of printed text in image pixels. */
data class TextLine(val text: String, val box: Box)

/**
 * Printed-text OCR (PP-OCRv3 detection + recognition, Apache-2.0, run by ONNX
 * Runtime). Only used to find the printed labels on the first scan of an
 * unknown layout; normal scans never run it. The same code runs on the phone
 * and in the desktop tests, which is why it replaces ML Kit.
 */
class PrintedTextReader(
    detModel: ByteArray,
    recModel: ByteArray,
    threads: Int = 4,
    /** Extra session options, e.g. an execution provider to compare on a device. */
    configure: (OrtSession.SessionOptions) -> Unit = {},
) : AutoCloseable {
    private val env = OrtEnvironment.getEnvironment()
    private val det: OrtSession
    private val rec: OrtSession
    private val dict: List<String>

    init {
        val opts = OrtSession.SessionOptions().apply {
            setIntraOpNumThreads(threads)
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            configure(this)
        }
        det = env.createSession(detModel, opts)
        rec = env.createSession(recModel, opts)
        // The character list ships inside the model's metadata; index 0 is
        // the CTC blank and a space follows the list.
        // (The list ends with a newline; a trailing empty entry would shift
        // the space class and drop every space from the output.)
        dict = rec.metadata.customMetadata["character"]!!.lines().dropLastWhile { it.isEmpty() } + " "
    }

    /**
     * Printed lines that can be field labels. Lines much wider than a label
     * (instruction sentences) are skipped: recognising them is most of the
     * cost on a slow phone and they never name a field.
     */
    fun read(gray: Mat, maxAspect: Double = MAX_LABEL_ASPECT): List<TextLine> {
        val boxes = detect(gray).filter { it.w <= maxAspect * it.h }
        return boxes.zip(recognize(gray, boxes)).filter { it.second.first.isNotBlank() }.map { TextLine(it.second.first, it.first) }
    }

    /**
     * DB text detection on the page scaled to [DET_SIDE] px on its longer
     * side: up as well as down, so small print in a low-resolution photo is
     * still found.
     */
    fun detect(gray: Mat): List<Box> {
        val s = DET_SIDE.toDouble() / max(gray.cols(), gray.rows())
        val w = max(32, ((gray.cols() * s) / 32).roundToInt() * 32)
        val h = max(32, ((gray.rows() * s) / 32).roundToInt() * 32)
        val resized = Mat()
        Imgproc.resize(gray, resized, Size(w.toDouble(), h.toDouble()), 0.0, 0.0, if (s < 1) Imgproc.INTER_AREA else Imgproc.INTER_CUBIC)
        val f = Mat()
        resized.convertTo(f, CvType.CV_32F, 1 / 255.0)
        val plane = FloatArray(w * h)
        f.get(0, 0, plane)
        resized.release(); f.release()
        val input = FloatArray(3 * w * h)
        val mean = floatArrayOf(0.485f, 0.456f, 0.406f)
        val std = floatArrayOf(0.229f, 0.224f, 0.225f)
        for (c in 0 until 3) for (i in plane.indices) input[c * w * h + i] = (plane[i] - mean[c]) / std[c]

        val prob = Mat(h, w, CvType.CV_32F)
        OnnxTensor.createTensor(env, FloatBuffer.wrap(input), longArrayOf(1, 3, h.toLong(), w.toLong())).use { t ->
            det.run(mapOf(det.inputNames.first() to t)).use { out ->
                val buf = (out[0] as OnnxTensor).floatBuffer
                val arr = FloatArray(buf.remaining()).also { buf.get(it) }
                prob.put(0, 0, arr)
            }
        }
        val bin = Mat()
        Imgproc.threshold(prob, bin, 0.3, 255.0, Imgproc.THRESH_BINARY)
        bin.convertTo(bin, CvType.CV_8U)
        Imgproc.dilate(bin, bin, Mat.ones(2, 2, CvType.CV_8U))
        val contours = ArrayList<MatOfPoint>()
        Imgproc.findContours(bin, contours, Mat(), Imgproc.RETR_LIST, Imgproc.CHAIN_APPROX_SIMPLE)
        val sx = gray.cols().toDouble() / w
        val sy = gray.rows().toDouble() / h
        val boxes = contours.mapNotNull { c ->
            val r = Imgproc.boundingRect(c)
            if (min(r.width, r.height) < 3) return@mapNotNull null
            val score = Core.mean(prob.submat(r), bin.submat(r)).`val`[0]
            if (score < 0.5) return@mapNotNull null
            // Unclip: the network predicts a shrunk text kernel.
            val area = Imgproc.contourArea(c)
            val perimeter = Imgproc.arcLength(org.opencv.core.MatOfPoint2f(*c.toArray()), true)
            val d = area * 1.6 / max(perimeter, 1.0)
            Box(
                max(0.0, (r.x - d) * sx), max(0.0, (r.y - d) * sy),
                min(gray.cols().toDouble(), (r.x + r.width + d) * sx), min(gray.rows().toDouble(), (r.y + r.height + d) * sy),
            )
        }
        prob.release(); bin.release()
        return boxes.sortedWith(compareBy({ it.y0 }, { it.x0 }))
    }

    /**
     * CRNN recognition of each box, batched by width: text and confidence
     * (the least certain character's probability).
     */
    fun recognize(gray: Mat, boxes: List<Box>): List<Pair<String, Double>> {
        val crops = boxes.map { b ->
            val r = Rect(b.x0.toInt(), b.y0.toInt(), max(1, (b.x1 - b.x0).toInt()), max(1, (b.y1 - b.y0).toInt()))
            val cw = min(REC_MAX_WIDTH, ceil(REC_HEIGHT * r.width.toDouble() / r.height).toInt()).coerceAtLeast(8)
            val m = Mat()
            Imgproc.resize(gray.submat(r), m, Size(cw.toDouble(), REC_HEIGHT.toDouble()), 0.0, 0.0, Imgproc.INTER_LINEAR)
            m
        }
        val out = arrayOfNulls<Pair<String, Double>>(boxes.size)
        crops.indices.sortedBy { crops[it].cols() }.chunked(8).forEach { batch ->
            val bw = batch.maxOf { crops[it].cols() }
            val plane = REC_HEIGHT * bw
            val input = FloatArray(batch.size * 3 * plane) // zero padding, as PaddleOCR does
            val row = FloatArray(bw)
            batch.forEachIndexed { n, idx ->
                val f = Mat()
                crops[idx].convertTo(f, CvType.CV_32F, 2 / 255.0, -1.0)
                for (y in 0 until REC_HEIGHT) {
                    f.get(y, 0, row)
                    for (c in 0 until 3) System.arraycopy(row, 0, input, n * 3 * plane + c * plane + y * bw, f.cols())
                }
                f.release()
            }
            OnnxTensor.createTensor(env, FloatBuffer.wrap(input), longArrayOf(batch.size.toLong(), 3, REC_HEIGHT.toLong(), bw.toLong())).use { t ->
                rec.run(mapOf(rec.inputNames.first() to t)).use { res ->
                    val tensor = res[0] as OnnxTensor
                    val shape = tensor.info.shape
                    val frames = shape[1].toInt()
                    val classes = shape[2].toInt()
                    val buf = tensor.floatBuffer
                    batch.forEachIndexed { n, idx ->
                        val sb = StringBuilder()
                        var conf = 1.0
                        var prev = 0
                        for (tt in 0 until frames) {
                            var best = 0
                            var bp = -1f
                            val base = (n * frames + tt) * classes
                            for (c in 0 until classes) {
                                val v = buf.get(base + c)
                                if (v > bp) { bp = v; best = c }
                            }
                            if (best != 0 && best != prev && best - 1 < dict.size) {
                                sb.append(dict[best - 1])
                                conf = min(conf, bp.toDouble())
                            }
                            prev = best
                        }
                        out[idx] = sb.toString().trim() to (if (sb.isEmpty()) 0.0 else conf)
                    }
                }
            }
        }
        crops.forEach { it.release() }
        return out.map { it ?: ("" to 0.0) }
    }

    override fun close() {
        det.close(); rec.close()
    }

    companion object {
        const val DET_SIDE = 1280

        /** "Registered No." is ~7x as wide as tall; a sentence is 20-40x. */
        const val MAX_LABEL_ASPECT = 14.0
        const val REC_HEIGHT = 48
        const val REC_MAX_WIDTH = 640
    }
}
