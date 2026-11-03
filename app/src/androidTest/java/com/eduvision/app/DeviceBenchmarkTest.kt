package com.eduvision.app

import android.os.Bundle
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.eduvision.core.recog.FieldModel
import com.eduvision.core.recog.PrintedTextReader
import com.eduvision.core.recog.SheetReader
import com.eduvision.core.validate.ScanValidator
import org.json.JSONObject
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.opencv.android.OpenCVLoader
import org.opencv.core.Mat
import org.opencv.core.MatOfByte
import org.opencv.imgcodecs.Imgcodecs

/**
 * Runs the full pipeline on a real phone (Firebase Test Lab or a connected
 * device) and reports per-stage latency. Uses only synthetic sheets
 * (training/synthetic/make_sheet.py): no student data leaves the developer's
 * machine. Results go to logcat under the tag EduBench and to the
 * instrumentation status.
 */
@RunWith(AndroidJUnit4::class)
class DeviceBenchmarkTest {
    private val instr = InstrumentationRegistry.getInstrumentation()
    private val app = instr.targetContext
    private val test = instr.context

    private fun model(name: String) = app.assets.open("models/$name").use { it.readBytes() }
    private fun bench(name: String) = test.assets.open("bench/$name").use { it.readBytes() }
    private fun gray(name: String): Mat = Imgcodecs.imdecode(MatOfByte(*bench(name)), Imgcodecs.IMREAD_GRAYSCALE)

    private fun report(key: String, value: Any) {
        Log.i("EduBench", "$key=$value")
        instr.sendStatus(0, Bundle().apply { putString("EduBench", "$key=$value") })
    }

    @Test
    fun pipelineLatencyOnDevice() {
        report("device", "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL} API ${android.os.Build.VERSION.SDK_INT} " +
            "cores ${Runtime.getRuntime().availableProcessors()} abi ${android.os.Build.SUPPORTED_ABIS.first()}")
        var t = System.nanoTime()
        fun lap(): Long = ((System.nanoTime() - t) / 1_000_000).also { t = System.nanoTime() }

        assertTrue(OpenCVLoader.initLocal())
        report("load_opencv_ms", lap())
        val fieldModel = FieldModel(model("field_recognizer_v2.onnx"), threads = 2)
        report("load_field_model_ms", lap())
        val text = PrintedTextReader(model("ppocr_v3_det.onnx"), model("ppocr_v3_rec.onnx"),
            Runtime.getRuntime().availableProcessors().coerceIn(1, 4))
        report("load_ocr_models_ms", lap())
        val reader = SheetReader(fieldModel) { text }

        val clean = gray("sheet_clean.png")
        lap()
        val layout = reader.createTemplate(clean, "syn", "Synthetic")
        report("first_scan_layout_ms", lap())
        assertNotNull("labels not found", layout)
        val template = layout!!.template.copy(registrationMask = "DDADDADDXX", partBMax = 60)
        report("layout_fields", template.fields.joinToString { it.kind.name })

        val truth = JSONObject(String(bench("truth.json")))
        var right = 0
        var total = 0
        val totals = ArrayList<Long>()
        // Twice: the first pass includes one-time warm-up (ORB on the reference, ORT kernels).
        for (pass in 1..2) for (name in truth.keys()) {
            val photo = gray(name)
            val r = ScanValidator.validate(reader.read(photo, template, layout.reference), template)
            val want = truth.getJSONObject(name)
            if (pass == 2) {
                listOf(r.registrationNo.value to want.getString("registration"), r.partA.value to want.getString("partA"),
                    r.partB.value to want.getString("partB")).forEach { (got, w) -> total++; if (got == w) right++ }
                totals += r.timingsMs["total"]!!
            }
            report("scan_${pass}_$name", "${r.registrationNo.value} ${r.partA.value} ${r.partB.value} ${r.timingsMs}")
            photo.release()
        }
        report("read_right", "$right/$total")
        report("scan_ms_median", totals.sorted()[totals.size / 2])
        report("scan_ms_max", totals.max())
        assertTrue("read $right/$total", right >= total - 1)
    }
}
