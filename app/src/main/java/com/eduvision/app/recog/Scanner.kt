package com.eduvision.app.recog

import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Log
import androidx.exifinterface.media.ExifInterface
import com.eduvision.app.data.TemplateStore
import com.eduvision.core.model.ScanResult
import com.eduvision.core.model.SheetTemplate
import com.eduvision.core.recog.FieldModel
import com.eduvision.core.recog.PrintedTextReader
import com.eduvision.core.recog.SheetNotRecognized
import com.eduvision.core.recog.SheetReader
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.opencv.android.OpenCVLoader
import org.opencv.core.Core
import org.opencv.core.Mat
import org.opencv.core.Size
import org.opencv.imgcodecs.Imgcodecs
import org.opencv.imgproc.Imgproc
import java.io.File
import kotlin.math.max

class NoLayoutFound : Exception(
    "Could not find the printed labels on this sheet (\"Registered No.\", \"Part-A Total\", " +
        "\"GRAND TOTAL\"). Photograph the whole page, or create a template and draw its boxes.")

/** One scan: the result, the template that read it, and whether that template was just created. */
data class Scan(val result: ScanResult, val template: SheetTemplate, val newLayout: Boolean, val photo: File)

/**
 * The recognition engine of the app: owns the models (loaded once, off the
 * main thread) and picks or creates the template for each photo.
 */
class Scanner(private val context: Context, private val templates: TemplateStore) {
    private val lock = Mutex()
    private var reader: SheetReader? = null
    private var textReader: PrintedTextReader? = null

    private fun asset(name: String) = context.assets.open("models/$name").use { it.readBytes() }

    /** Loads OpenCV and the handwriting model; the label OCR loads on first need. */
    suspend fun warmUp(): SheetReader = lock.withLock { readerLocked() }

    private fun readerLocked(): SheetReader = reader ?: run {
        check(OpenCVLoader.initLocal()) { "OpenCV failed to load" }
        val threads = Runtime.getRuntime().availableProcessors().coerceIn(1, 4)
        SheetReader(FieldModel(asset(MODEL), threads = 2)) {
            textReader ?: PrintedTextReader(asset("ppocr_v3_det.onnx"), asset("ppocr_v3_rec.onnx"), threads).also { textReader = it }
        }.also { reader = it }
    }

    /**
     * Reads the sheet in [photo]: with the active template, else any other
     * saved template the photo matches, else a new template found from the
     * printed labels.
     */
    suspend fun scan(photo: File): Scan = withContext(Dispatchers.Default) {
        lock.withLock {
            val r = readerLocked()
            val t0 = System.nanoTime()
            val gray = loadGray(photo)
            val decodeMs = (System.nanoTime() - t0) / 1_000_000
            try {
                val active = templates.activeId
                val candidates = templates.all().sortedBy { if (it.id == active) 0 else 1 }
                for (t in candidates) {
                    val ref = templates.reference(t) ?: continue
                    if (t.fields.isEmpty()) continue
                    try {
                        val res = r.read(gray, t, ref, photo.path)
                        if (t.id != active) templates.activeId = t.id
                        return@withLock Scan(res.withDecode(decodeMs), t, false, photo)
                    } catch (_: SheetNotRecognized) {
                        // Try the next saved layout.
                    }
                }
                val l0 = System.nanoTime()
                val layout = r.createTemplate(gray, templates.newId(), "Sheet layout ${candidates.size + 1}") ?: throw NoLayoutFound()
                val layoutMs = (System.nanoTime() - l0) / 1_000_000
                templates.save(layout.template, layout.reference)
                templates.activeId = layout.template.id
                val saved = templates.get(layout.template.id)!!
                val res = r.read(gray, saved, layout.reference, photo.path)
                Scan(res.withDecode(decodeMs).let { it.copy(timingsMs = it.timingsMs + ("layout" to layoutMs)) }, saved, true, photo)
            } finally {
                gray.release()
            }
        }
    }

    /** Re-reads [photo] with [template], e.g. after the teacher set the registration format. */
    suspend fun reread(photo: File, template: SheetTemplate): ScanResult = withContext(Dispatchers.Default) {
        lock.withLock {
            val r = readerLocked()
            val gray = loadGray(photo)
            try {
                r.read(gray, template, templates.reference(template) ?: error("Template has no reference image"), photo.path)
            } finally {
                gray.release()
            }
        }
    }

    /** A template from a sample photo; boxes from the labels when they are found. */
    suspend fun templateFromPhoto(photo: File, name: String): SheetTemplate = withContext(Dispatchers.Default) {
        lock.withLock {
            val r = readerLocked()
            val gray = loadGray(photo)
            try {
                val layout = r.createTemplate(gray, templates.newId(), name)
                if (layout != null) {
                    templates.save(layout.template, layout.reference); templates.get(layout.template.id)!!
                } else {
                    val t = SheetTemplate(templates.newId(), name)
                    templates.save(t, com.eduvision.core.recog.Aligner.downscale(gray, SheetReader.REFERENCE_SIDE))
                    templates.get(t.id)!!
                }
            } finally {
                gray.release()
            }
        }
    }

    private fun ScanResult.withDecode(ms: Long) = copy(timingsMs = linkedMapOf("decode" to ms) + timingsMs)

    companion object {
        const val MODEL = "field_recognizer_v3.onnx"
        private const val MAX_SIDE = 2400

        /** 8-bit grayscale, upright (EXIF applied), longer side at most 2400 px. */
        fun loadGray(file: File): Mat {
            val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.path, opts)
            val longest = max(opts.outWidth, opts.outHeight)
            // OpenCV decodes at 1/2, 1/4 directly, far cheaper than full size + resize.
            val flag = when {
                longest >= MAX_SIDE * 4 -> Imgcodecs.IMREAD_REDUCED_GRAYSCALE_4
                longest >= MAX_SIDE * 2 -> Imgcodecs.IMREAD_REDUCED_GRAYSCALE_2
                else -> Imgcodecs.IMREAD_GRAYSCALE
            } or Imgcodecs.IMREAD_IGNORE_ORIENTATION
            var m = Imgcodecs.imread(file.path, flag)
            if (m.empty()) error("Could not open the photo")
            m = rotate(m, ExifInterface(file.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL))
            val s = MAX_SIDE.toDouble() / max(m.cols(), m.rows())
            if (s < 1) {
                val out = Mat()
                Imgproc.resize(m, out, Size(), s, s, Imgproc.INTER_AREA)
                m.release(); m = out
            }
            return m
        }

        private fun rotate(m: Mat, orientation: Int): Mat {
            val code = when (orientation) {
                ExifInterface.ORIENTATION_ROTATE_90 -> Core.ROTATE_90_CLOCKWISE
                ExifInterface.ORIENTATION_ROTATE_180 -> Core.ROTATE_180
                ExifInterface.ORIENTATION_ROTATE_270 -> Core.ROTATE_90_COUNTERCLOCKWISE
                else -> return m
            }
            val out = Mat()
            Core.rotate(m, out, code)
            m.release()
            return out
        }

        /** Copies a content Uri (scanner, picker) to a private file the decoder can read. */
        fun copyToFile(context: Context, uri: Uri): File {
            val dir = File(context.cacheDir, "scans").apply { mkdirs() }
            // Keep the last few scans only: they hold student data.
            dir.listFiles()?.sortedBy { it.lastModified() }?.dropLast(5)?.forEach { it.delete() }
            val out = File(dir, "scan_${System.currentTimeMillis()}.jpg")
            context.contentResolver.openInputStream(uri)!!.use { input -> out.outputStream().use { input.copyTo(it) } }
            Log.d("Scanner", "photo ${out.length() / 1024} KB")
            return out
        }

        /** Prefills a registration format from a reading: digits D, letters A. */
        fun guessMask(reading: String) = reading.map { if (it.isDigit()) 'D' else 'A' }.joinToString("")
    }
}
