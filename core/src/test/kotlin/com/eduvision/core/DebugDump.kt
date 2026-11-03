package com.eduvision.core

import com.eduvision.core.recog.Aligner
import com.eduvision.core.recog.Box
import com.eduvision.core.recog.CellFinder
import com.eduvision.core.recog.SheetReader
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.opencv.core.Core
import org.opencv.core.Mat
import org.opencv.core.Point
import org.opencv.imgcodecs.Imgcodecs
import java.io.File

/** Writes field patches under core/build/debug for eyeballing. Run with DEBUG_DUMP=1. */
class DebugDump {
    @Test
    fun dump() {
        assumeTrue(System.getenv("DEBUG_DUMP") == "1")
        RealSheetsTest.setUp()
        val out = File(RealSheetsTest.root, "core/build/debug").apply { mkdirs() }
        val layout = RealSheetsTest.reader.createTemplate(RealSheetsTest.gray(RealSheetsTest.annotations.keys.first { "13.33" in it }), "t", "t")!!
        Imgcodecs.imwrite(File(out, "reference.png").path, layout.reference)
        val aligner = Aligner(layout.reference)
        for (name in RealSheetsTest.annotations.keys) {
            val photo = RealSheetsTest.gray(name)
            val fit = aligner.fit(photo)!!
            val tag = name.takeLast(16).replace(" ", "_").replace(".jpeg", "")
            for (f in layout.template.fields) {
                val r = layout.reference
                val box = Box(f.box.left * r.cols(), f.box.top * r.rows(), f.box.right * r.cols(), f.box.bottom * r.rows())
                val ref = CellFinder.warpPatch(r, SheetReader.identity(), box, 2.0, 1.0).first
                val tiles = mutableListOf(ref)
                fit.candidates(Point((box.x0 + box.x1) / 2, (box.y0 + box.y1) / 2)).forEach { h ->
                    tiles += CellFinder.warpPatch(photo, h, box, 2.0, 1.0).first
                }
                if (f.kind == com.eduvision.core.model.FieldKind.REGISTRATION) {
                    val h = fit.regional(Point((box.x0 + box.x1) / 2, (box.y0 + box.y1) / 2))
                    val (p, pb) = CellFinder.warpPatch(photo, h, box, SheetReader.scaleFor(box), 0.5)
                    val cells = CellFinder.findComb(p, pb, 10)
                    val c = Mat(); org.opencv.imgproc.Imgproc.cvtColor(p, c, org.opencv.imgproc.Imgproc.COLOR_GRAY2BGR)
                    org.opencv.imgproc.Imgproc.rectangle(c, Point(pb.x0, pb.y0), Point(pb.x1, pb.y1), org.opencv.core.Scalar(0.0, 0.0, 255.0), 1)
                    cells?.forEach { b -> val i = b.inset(0.08, 2.0); org.opencv.imgproc.Imgproc.rectangle(c, Point(i.x0, i.y0), Point(i.x1, i.y1), org.opencv.core.Scalar(0.0, 180.0, 0.0), 1) }
                    Imgcodecs.imwrite(File(out, "${tag}_comb.png").path, c)
                }
                val all = Mat()
                Core.vconcat(tiles, all)
                Imgcodecs.imwrite(File(out, "${tag}_${f.kind}.png").path, all)
            }
        }
    }
}
