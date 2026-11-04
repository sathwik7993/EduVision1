package com.eduvision.core

import com.eduvision.core.validate.Dates
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

class DatesTest {
    private val today = LocalDate.of(2026, 11, 4)
    private fun canon(s: String) = Dates.parse(s, today)?.canonical

    @Test fun usualWritings() {
        assertEquals("04/11/2026", canon("04/11/2026"))
        assertEquals("04/11/2026", canon("4-11-26"))
        assertEquals("04/11/2026", canon("4.11.2026"))
        assertEquals("04/11/2026", canon("04 11 26"))
        assertEquals("04/11/2026", canon("041126"))
        assertEquals("04/11/2026", canon("04112026"))
    }

    @Test fun lettersReadForDigitsAreNoted() {
        val p = Dates.parse("O4/1l/2O26", today)!!
        assertEquals("04/11/2026", p.canonical)
        assertTrue(p.neededLookAlikes)
        assertFalse(Dates.parse("04/11/2026", today)!!.neededLookAlikes)
    }

    @Test fun impossibleDatesAreRefused() {
        assertNull(canon("34/11/2026"))
        assertNull(canon("04/13/2026"))
        assertNull(canon("30/02/2026"))
        assertNull(canon("04/11/1998"))   // too old for an exam sheet
        assertNull(canon("04/11/2030"))   // future
        assertNull(canon("Social"))
        assertNull(canon("4/11"))
    }

    @Test fun dateLabels() {
        assertTrue(Dates.isDateField("Date of Exam"))
        assertTrue(Dates.isDateField("Date"))
        assertFalse(Dates.isDateField("Signature of the Candidate"))
        assertFalse(Dates.isDateField("Course Name"))
    }
}
