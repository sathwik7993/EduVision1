package com.eduvision.core

import com.eduvision.core.validate.KnownValues
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class KnownValuesTest {
    private val course = KnownValues(mapOf("Social Networks" to 5, "Compiler Design" to 3, "CH.SATHWIK" to 1))

    @Test fun misreadCourseNameGetsTheRepeatedValue() {
        assertEquals("Social Networks", course.suggest("SoualNehuorks"))
        assertEquals("Social Networks", course.suggest("socalNctworks."))
    }

    @Test fun sameTextInOtherFormattingGetsTheConfirmedSpelling() {
        assertEquals("Social Networks", course.suggest("socialnetworks"))
    }

    @Test fun exactValueNeedsNoSuggestion() = assertNull(course.suggest("Social Networks"))

    @Test fun unrelatedTextGetsNothing() = assertNull(course.suggest("Data Mining"))

    @Test fun valueSeenOnceIsNotSuggested() = assertNull(course.suggest("CH.SATHWIR"))

    @Test fun tieIsRefused() {
        val sections = KnownValues(mapOf("CSM-04" to 9, "CSM-05" to 7))
        assertNull(sections.suggest("CSM-0"))
        assertEquals("CSM-04", sections.suggest("csm-04"))
    }
}
