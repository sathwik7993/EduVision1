package com.eduvision.core

import com.eduvision.core.model.ExtractedField
import com.eduvision.core.model.FieldKind
import com.eduvision.core.model.LabelledMark
import com.eduvision.core.model.NormBox
import com.eduvision.core.model.ScanResult
import com.eduvision.core.model.SheetTemplate
import com.eduvision.core.model.TemplateField
import com.eduvision.core.recog.CtcDecoder
import com.eduvision.core.recog.DIGITS
import com.eduvision.core.recog.Probs
import com.eduvision.core.validate.Roster
import com.eduvision.core.validate.ScanValidator
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ValidationTest {
    private val box = NormBox(0.0, 0.0, 0.1, 0.1)
    private val template = SheetTemplate(
        id = "cat", name = "CAT", registrationMask = "DDADDADDXX", partAMax = 40, partBMax = 60,
        fields = listOf(TemplateField(FieldKind.PART_A, box), TemplateField(FieldKind.PART_B, box)),
    )

    private fun f(v: String, c: Double = 0.99, alt: String? = null) = ExtractedField(v, c, alternative = alt)
    private fun result(reg: ExtractedField = f("23H51A66K1"), a: String = "30", b: String = "50") =
        ScanResult(reg, f(a), f(b))

    @Test fun cleanSheetIsReady() {
        val r = ScanValidator.validate(result(), template)
        assertTrue(r.fieldsNeedingReview.toString(), r.isReadyToSave)
        assertEquals(80, r.total)
    }

    @Test fun markAboveMaximumIsFlaggedAndBlocks() {
        val r = ScanValidator.validate(result(b = "80"), template)
        assertEquals("Above the maximum of 60", r.partB.issue)
        assertEquals(listOf("Part-B: Above the maximum of 60"), ScanValidator.blockingErrors(r, template))
    }

    @Test fun incompleteRegistrationIsFlagged() {
        val r = ScanValidator.validate(result(reg = f("23")), template)
        assertEquals("Incomplete: read 2 of 10 characters", r.registrationNo.issue)
    }

    @Test fun registrationBelowStricterGateIsFlagged() {
        val r = ScanValidator.validate(result(reg = f("23H51A66K1", 0.93)), template)
        assertEquals("Not certain enough for a registration number", r.registrationNo.issue)
    }

    @Test fun confusableAlternativeIsSettledByRoster() {
        val roster = Roster(listOf("23H51A66D9", "23H51A66K1"))
        val r = ScanValidator.validate(result(reg = f("23H51A6609", alt = "23H51A66D9")), template, roster)
        assertEquals("23H51A66D9", r.registrationNo.suggestion)
        // Reading on the roster: the alternative does not matter.
        val ok = ScanValidator.validate(result(reg = f("23H51A66K1", alt = "23H51A66KI")), template, roster)
        assertNull(ok.registrationNo.issue)
    }

    @Test fun confusableWithoutRosterGoesToReview() {
        val r = ScanValidator.validate(result(reg = f("23H51A6609", alt = "23H51A66D9")), template)
        assertEquals("Could also be 23H51A66D9", r.registrationNo.issue)
        assertTrue(r.registrationNo.needsReview)
    }

    @Test fun writtenTotalMustMatchSum() {
        val r = ScanValidator.validate(
            result(a = "10", b = "20").copy(writtenTotals = listOf(LabelledMark("Grand total", "", f("40")))), template)
        assertEquals("Grand total reads 40, but Part-A + Part-B = 30", r.writtenTotals[0].field.issue)
    }

    @Test fun questionsMustAddUpToPartTotal() {
        val qs = listOf(LabelledMark("Q1", "A", f("5")), LabelledMark("Q2", "A", f("4")))
        val r = ScanValidator.validate(result(a = "10").copy(questions = qs), template)
        assertTrue(r.partA.issue!!.startsWith("Question marks add up to 9"))
    }

    @Test fun duplicateIsFlagged() {
        val r = ScanValidator.validate(result(), template, alreadySaved = setOf("23H51A66K1"))
        assertEquals("Already in the results sheet", r.registrationNo.issue)
    }

    @Test fun teacherValueIsNeverFlagged() {
        val r = ScanValidator.validate(result(reg = ExtractedField.manual("23")), template)
        assertFalse(r.registrationNo.needsReview)
    }

    @Test fun rosterClosestRefusesAmbiguity() {
        val roster = Roster(listOf("23H51A6601", "23H51A6602"))
        assertNull(roster.closest("23H51A6603"))
        assertEquals("23H51A6601", Roster(listOf("23H51A6601")).closest("23H51A6607"))
    }

    @Test fun rosterColumnFromHeader() {
        val r = Roster.fromRows(listOf(listOf("S.No", "Roll No", "Name"), listOf("1", "23h51a66k1", "A"), listOf("2", "", "B")))
        assertEquals(setOf("23H51A66K1"), r.registrations)
    }

    @Test fun templateJsonRoundTrip() {
        assertEquals(template, SheetTemplate.fromJson(template.toJson()))
    }

    /** Probabilities for frames given as (class char or '-' for blank, p). */
    private fun probs(vararg frames: Pair<Char, Float>): Probs {
        val classes = 37
        val data = FloatArray(frames.size * classes)
        frames.forEachIndexed { t, (c, p) ->
            val idx = if (c == '-') 0 else "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ".indexOf(c) + 1
            for (k in 0 until classes) data[t * classes + k] = (1 - p) / (classes - 1)
            data[t * classes + idx] = p
        }
        return Probs(data, frames.size, classes)
    }

    @Test fun ctcCollapsesRepeatsAndUsesMinConfidence() {
        val r = CtcDecoder.decode(probs('4' to 0.9f, '4' to 0.95f, '-' to 0.9f, '0' to 0.8f), DIGITS)
        assertEquals("40", r.text)
        assertEquals(0.8, r.confidence, 1e-6)
    }

    @Test fun ctcCapsConfidenceByDroppedLetter() {
        // The model was sure of an "S": the "5" chosen in its place is doubtful.
        val r = CtcDecoder.decode(probs('S' to 0.9f), DIGITS)
        assertTrue(r.confidence <= 0.1 + 1e-6)
    }

    @Test fun dateFieldsAreChecked() {
        fun date(v: String) = ScanValidator.validate(result().copy(extras = listOf(
            LabelledMark("Date of Exam", "", f(v), blocking = false))), template).extras.single().field
        val y = java.time.LocalDate.now().year
        assertNull(date("04/11/$y").issue)
        assertNotNull(date("34/11/$y").issue)
        val swapped = date("O4/11/$y")
        assertEquals("04/11/$y", swapped.suggestion)
        assertTrue(swapped.needsReview)
        assertEquals("O4/11/$y", swapped.value) // never rewritten
    }

    @Test fun layoutWithoutPartTotalsCanBeSaved() {
        val extra = LabelledMark("Internal", "", f("18"), maxMarks = 20)
        val r = ScanValidator.validate(ScanResult(f("23H51A66K1"), ExtractedField.NOT_ON_SHEET, ExtractedField.NOT_ON_SHEET,
            extras = listOf(extra)), template.copy(fields = emptyList()))
        assertTrue(r.fieldsNeedingReview.toString(), r.isReadyToSave)
        val over = ScanValidator.validate(r.copy(extras = listOf(extra.copy(field = f("25")))), template)
        assertEquals("Above the maximum of 20", over.extras[0].field.issue)
    }
}
