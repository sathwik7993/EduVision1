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
}
