package com.eduvision.app

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import com.eduvision.app.data.ResultsStore
import com.eduvision.app.data.Xlsx
import com.eduvision.core.model.ExtractedField
import com.eduvision.core.model.ScanResult
import com.eduvision.core.validate.Roster
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.ByteArrayOutputStream

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [35])
class DataTest {
    private val context get() = ApplicationProvider.getApplicationContext<Application>()

    @Test fun xlsxRoundTrip() {
        val out = ByteArrayOutputStream()
        Xlsx.write(out, "Results", listOf(
            listOf(Xlsx.Text("Registration No"), Xlsx.Text("Total")),
            listOf(Xlsx.Text("23H51A66K1 & <x>"), Xlsx.Num(30)),
        ))
        val rows = Xlsx.readFirstSheet(out.toByteArray().inputStream())
        assertEquals(listOf(listOf("Registration No", "Total"), listOf("23H51A66K1 & <x>", "30")), rows)
    }

    @Test fun rosterFromWorkbook() {
        val out = ByteArrayOutputStream()
        Xlsx.write(out, "Class", listOf(
            listOf(Xlsx.Text("S.No"), Xlsx.Text("Hall Ticket No"), Xlsx.Text("Name")),
            listOf(Xlsx.Num(1), Xlsx.Text("23h51a66k1"), Xlsx.Text("A")),
            listOf(Xlsx.Num(2), Xlsx.Text("23H51A66D9"), Xlsx.Text("B")),
        ))
        val roster = Roster.fromRows(Xlsx.readFirstSheet(out.toByteArray().inputStream()))
        assertEquals(setOf("23H51A66K1", "23H51A66D9"), roster.registrations)
    }

    @Test fun resultsReplaceSameStudentAndExport() {
        val store = ResultsStore(context)
        store.clear()
        fun r(reg: String, a: String, b: String) = ScanResult(ExtractedField.manual(reg), ExtractedField.manual(a), ExtractedField.manual(b))
        store.save(r("23h51a66k1", "10", "20"), "CAT")
        store.save(r("23H51A66D9", "40", "50"), "CAT")
        store.save(r("23H51A66K1", "12", "20"), "CAT")
        assertEquals(2, store.all().size)
        assertEquals(32, store.all().first { it.registrationNo == "23H51A66K1" }.total)
        val rows = Xlsx.readFirstSheet(store.exportXlsx().inputStream())
        assertEquals(listOf("Registration No", "Part-A", "Part-B", "Total", "Scanned At", "Layout"), rows[0])
        assertEquals(listOf("23H51A66D9", "40", "50", "90"), rows[1].take(4))
        assertEquals(listOf("23H51A66K1", "12", "20", "32"), rows[2].take(4))
    }

    @Test fun customFieldsBecomeColumns() {
        val store = ResultsStore(context)
        store.clear()
        val r = ScanResult(ExtractedField.manual("19K41A0233"), ExtractedField.NOT_ON_SHEET, ExtractedField.NOT_ON_SHEET,
            extras = listOf(com.eduvision.core.model.LabelledMark("Internal", "", ExtractedField.manual("18")),
                com.eduvision.core.model.LabelledMark("Course code", "", ExtractedField.manual("CS301"))))
        store.save(r, "Greenfield")
        val rows = Xlsx.readFirstSheet(store.exportXlsx().inputStream())
        assertEquals(listOf("Registration No", "Part-A", "Part-B", "Total", "Internal", "Course code", "Scanned At", "Layout"), rows[0])
        assertEquals(listOf("19K41A0233", "0", "0", "0", "18", "CS301"), rows[1].take(6))
    }

    @Test fun confirmedCourseNameIsSuggestedFromTheSecondSheetOn() {
        val store = com.eduvision.app.data.KnownValuesStore(context)
        store.record("t1", mapOf("Course Name" to "Social Networks", "Name of the Student" to "CH.SATHWIK"))
        org.junit.Assert.assertNull(store.of("t1", "Course Name").suggest("SoualNehuorks"))
        store.record("t1", mapOf("Course Name" to "Social Networks", "Name of the Student" to "B.RAVI"))
        assertEquals("Social Networks", store.of("t1", "Course Name").suggest("SoualNehuorks"))
        org.junit.Assert.assertNull(store.of("t1", "Name of the Student").suggest("CH.SATHWIR"))
        org.junit.Assert.assertNull(store.of("t2", "Course Name").suggest("SoualNehuorks"))
    }
}
