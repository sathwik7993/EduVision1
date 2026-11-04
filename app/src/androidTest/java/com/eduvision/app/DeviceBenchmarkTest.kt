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
        val fieldModel = FieldModel(model("field_recognizer_v3.onnx"), threads = 1)
        report("load_field_model_ms", lap())
        val text = PrintedTextReader(model("ppocr_v3_det.onnx"), model("ppocr_v3_rec.onnx"),
            Runtime.getRuntime().availableProcessors().coerceIn(1, 4))
        report("load_ocr_models_ms", lap())
        // As the app runs it: fields in parallel, one thread per model call.
        val reader = SheetReader(fieldModel, SheetReader.defaultThreads()) { text }

        val clean = gray("sheet_clean.png")
        lap()
        val layout = reader.createTemplate(clean, "syn", "Synthetic")
        report("first_scan_layout_ms", lap())
        assertNotNull("labels not found", layout)
        val template = layout!!.template.copy(registrationMask = "DDADDADDXX", partBMax = 60)
        report("layout_fields", template.fields.joinToString { it.kind.name })

        val truth = JSONObject(String(bench("truth.json")))
        val names = truth.keys().asSequence().toList()

        /** Reads every synthetic photo twice (the first pass warms up); reports pass 2. */
        fun measure(tag: String, r: SheetReader): Pair<Int, Int> {
            var right = 0
            var total = 0
            val totals = ArrayList<Long>()
            for (pass in 1..2) for (name in names) {
                val photo = gray(name)
                val res = ScanValidator.validate(r.read(photo, template, layout.reference), template)
                val want = truth.getJSONObject(name)
                if (pass == 2) {
                    listOf(res.registrationNo.value to want.getString("registration"), res.partA.value to want.getString("partA"),
                        res.partB.value to want.getString("partB")).forEach { (got, w) -> total++; if (got == w) right++ }
                    totals += res.timingsMs["total"]!!
                    report("scan${tag}_$name", "${res.registrationNo.value} ${res.partA.value} ${res.partB.value} ${res.timingsMs}")
                }
                photo.release()
            }
            report("read_right$tag", "$right/$total")
            report("scan_ms_median$tag", totals.sorted()[totals.size / 2])
            report("scan_ms_max$tag", totals.max())
            return right to total
        }

        // As the app runs it, then variants to choose the next default from
        // device numbers: 0.4.0's one field at a time; int8 weights in the
        // LSTM and head (identical results on the desktop tests); ONNX
        // Runtime's XNNPACK kernels. Two rounds in turn, so a slow start or
        // a background task on the phone does not decide the comparison.
        val xnnpack: (ai.onnxruntime.OrtSession.SessionOptions) -> Unit = { it.addXnnpack(mapOf("intra_op_num_threads" to "1")) }
        val fp32 = model("field_recognizer_v3.onnx")
        val int8 = bench("field_recognizer_int8.onnx")
        val variants = listOf<Pair<String, () -> SheetReader>>(
            "" to { reader },
            "_serial" to { SheetReader(FieldModel(fp32, threads = 2), 1) { text } },
            "_int8" to { SheetReader(FieldModel(int8, threads = 1), SheetReader.defaultThreads()) { text } },
            "_xnnpack" to { SheetReader(FieldModel(fp32, threads = 1, configure = xnnpack), SheetReader.defaultThreads()) { text } },
            "_int8_xnnpack" to { SheetReader(FieldModel(int8, threads = 1, configure = xnnpack), SheetReader.defaultThreads()) { text } },
        )
        var right = 0
        var total = 0
        for (round in 1..2) for ((tag, make) in variants) {
            runCatching { make() }
                .onSuccess { r -> measure("${tag}_r$round", r).let { if (tag == "" && round == 1) { right = it.first; total = it.second } } }
                .onFailure { report("variant${tag}", "unavailable: ${it.message}") }
        }
        assertTrue("read $right/$total", right >= total - 1)
    }
}
