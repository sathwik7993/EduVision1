package com.eduvision.core.recog

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import java.nio.FloatBuffer
import kotlin.math.max
import kotlin.math.roundToInt

/** Per-frame class probabilities, row-major [frames, classes]; class 0 is the CTC blank. */
class Probs(val data: FloatArray, val frames: Int, val classes: Int) {
    operator fun get(t: Int, c: Int) = data[t * classes + c]
}

/**
 * The handwriting CRNN from training/recognizer (input `input` [1,1,32,W],
 * output `probs` [1,T,37]), run by ONNX Runtime on the CPU.
 */
class FieldModel(modelBytes: ByteArray, threads: Int = 2) : AutoCloseable {
    private val env = OrtEnvironment.getEnvironment()
    private val session: OrtSession = OrtSession.SessionOptions().use { opts ->
        // Entry-level phones have 2-4 big cores; more threads than that makes a
        // model this small slower, not faster.
        opts.setIntraOpNumThreads(threads)
        opts.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
        env.createSession(modelBytes, opts)
    }

    /** [gray] is an 8-bit grayscale crop, dark ink on light paper. */
    fun run(gray: Mat): Probs {
        val (data, width) = prepare(gray)
        OnnxTensor.createTensor(env, FloatBuffer.wrap(data), longArrayOf(1, 1, HEIGHT.toLong(), width.toLong())).use { t ->
            session.run(mapOf("input" to t)).use { out ->
                val tensor = out[0] as OnnxTensor
                val shape = tensor.info.shape
                val buf = tensor.floatBuffer
                val arr = FloatArray(buf.remaining()).also { buf.get(it) }
                return Probs(arr, shape[1].toInt(), shape[2].toInt())
            }
        }
    }

    override fun close() = session.close()

    companion object {
        const val HEIGHT = 32
        const val MIN_WIDTH = 16
        const val MAX_WIDTH = 512

        /**
         * Mirror of `prep()` in training/recognizer/eduvision_recognizer.py:
         * resize to height 32 keeping aspect (area when shrinking, bilinear
         * otherwise), invert so ink is high, min-max stretch, pad width to a
         * multiple of 4.
         */
        fun prepare(gray: Mat): Pair<FloatArray, Int> {
            val w = (gray.cols() * HEIGHT.toDouble() / max(gray.rows(), 1)).roundToInt().coerceIn(MIN_WIDTH, MAX_WIDTH)
            val shrink = w <= gray.cols() && HEIGHT <= gray.rows()
            val resized = Mat()
            Imgproc.resize(gray, resized, Size(w.toDouble(), HEIGHT.toDouble()), 0.0, 0.0,
                if (shrink) Imgproc.INTER_AREA else Imgproc.INTER_LINEAR)
            val mm = Core.minMaxLoc(resized)
            // x = 1 - v/255, stretched: (x - lo) / (hi - lo + 1e-3), lo = 1 - max/255.
            val lo = 1.0 - mm.maxVal / 255.0
            val range = (mm.maxVal - mm.minVal) / 255.0 + 1e-3
            val f = Mat()
            resized.convertTo(f, CvType.CV_32F, -1.0 / 255.0 / range, (1.0 - lo) / range)
            val padded = w + (4 - w % 4) % 4
            val out = FloatArray(HEIGHT * padded)
            val row = FloatArray(w)
            for (y in 0 until HEIGHT) {
                f.get(y, 0, row)
                System.arraycopy(row, 0, out, y * padded, w)
            }
            resized.release(); f.release()
            return out to padded
        }
    }
}
