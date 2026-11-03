package com.eduvision.core.validate

import com.eduvision.core.model.ExtractedField
import com.eduvision.core.model.FieldKind
import com.eduvision.core.model.ScanResult
import com.eduvision.core.model.SheetTemplate

/**
 * Cross-checks a recognised sheet against what is possible on paper.
 *
 * Every rule only ever adds doubt: a failed check attaches an issue, which
 * forces review whatever the model's confidence. Nothing is auto-corrected; a
 * roster match is offered as a suggestion the teacher has to accept.
 */
object ScanValidator {
    /**
     * Ten characters give ten chances to misread one, and a one-digit misread
     * of a roll number is usually another real student, so the roster cannot
     * catch it. On the synthetic eval 0.80 let ~2.5% through wrong, 0.95 ~0.15%.
     */
    const val REGISTRATION_TRUSTED_ABOVE = 0.95

    fun validate(
        result: ScanResult,
        template: SheetTemplate,
        roster: Roster = Roster.EMPTY,
        alreadySaved: Set<String> = emptySet(),
    ): ScanResult {
        val questions = result.questions.map { it.copy(field = it.field.withIssue(overMax(it.field, it.maxMarks))) }.toMutableList()
        var partA = result.partA.withIssue(overMax(result.partA, template.partAMax))
        var partB = result.partB.withIssue(overMax(result.partB, template.partBMax))

        // Per-question marks must add up to the part total written in its own box.
        for (part in listOf("A", "B")) {
            val kind = if (part == "A") FieldKind.PART_A else FieldKind.PART_B
            if (template.field(kind) == null) continue
            val idx = questions.indices.filter { questions[it].part == part }
            val total = if (part == "A") partA else partB
            // All cells blank is the common "examiner filled only the totals" case.
            if (idx.isEmpty() || total.isEmpty || idx.all { questions[it].field.isEmpty }) continue
            val sum = idx.sumOf { questions[it].value }
            val written = total.value.trim().toIntOrNull() ?: -1
            if (sum == written) continue
            val issue = "Question marks add up to $sum, but the Part-$part total reads $written"
            idx.forEach { questions[it] = questions[it].copy(field = questions[it].field.withIssue(issue)) }
            if (part == "A") partA = partA.withIssue(issue) else partB = partB.withIssue(issue)
        }

        // A total the examiner wrote must agree with Part-A + Part-B.
        val derived = (partA.value.trim().toIntOrNull() ?: 0) + (partB.value.trim().toIntOrNull() ?: 0)
        val written = result.writtenTotals.map { w ->
            if (w.field.isEmpty || w.field.value.trim().toIntOrNull() == derived) w
            else w.copy(field = w.field.withIssue("${w.label} reads ${w.field.value}, but Part-A + Part-B = $derived"))
        }

        return result.copy(
            registrationNo = checkRegistration(result.registrationNo, template, roster, alreadySaved),
            partA = partA,
            partB = partB,
            questions = questions,
            writtenTotals = written,
        )
    }

    /** Problems that block saving even after the teacher typed a value. */
    fun blockingErrors(result: ScanResult, template: SheetTemplate): List<String> = buildList {
        overMax(result.partA, template.partAMax)?.let { add("Part-A: $it") }
        overMax(result.partB, template.partBMax)?.let { add("Part-B: $it") }
        result.questions.forEach { q -> overMax(q.field, q.maxMarks)?.let { add("${q.label}: $it") } }
    }

    private fun checkRegistration(
        field: ExtractedField,
        template: SheetTemplate,
        roster: Roster,
        alreadySaved: Set<String>,
    ): ExtractedField {
        if (field.isEmpty || field.edited) return field
        val reg = Text.cleanRegistration(field.value)
        val issues = mutableListOf<String>()
        var suggestion: String? = null

        val mask = template.registrationMask?.takeIf { it.isNotEmpty() }
        val length = template.registrationLength
        when {
            length != null && reg.length < length -> issues += "Incomplete: read ${reg.length} of $length characters"
            length != null && reg.length > length -> issues += "Expected $length characters, read ${reg.length}"
            mask != null && !matchesMask(reg, mask) -> issues += "Does not match the format $mask"
            mask == null -> {
                val pattern = template.registrationPattern?.let(::Regex) ?: SheetTemplate.defaultRegistrationPattern
                if (!pattern.matches(reg)) issues += "Does not match the registration number format"
            }
        }

        val alt = field.alternative?.let(Text::cleanRegistration)
        if (!roster.isEmpty && reg !in roster) {
            suggestion = if (alt != null && alt in roster) alt else roster.closest(reg)
            issues += "Not on the class roster"
        } else if (roster.isEmpty && alt != null) {
            // 0/D, 1/I, 5/S... look alike in handwriting; without a roster
            // only the teacher can tell which one this student wrote.
            suggestion = alt
            issues += "Could also be $alt"
        }

        if (field.confidence >= ExtractedField.TRUSTED_ABOVE && field.confidence < REGISTRATION_TRUSTED_ABOVE) {
            issues += "Not certain enough for a registration number"
        }

        // A second sheet with the same number is more often a misread of a
        // neighbouring student than a genuine re-scan.
        if (reg in alreadySaved) issues += "Already in the results sheet"

        var out = field
        if (issues.isNotEmpty()) out = out.withIssue(issues.joinToString("; "), suggestion)
        return out
    }

    /** D digit, A letter, X either. */
    fun matchesMask(reg: String, mask: String): Boolean {
        if (reg.length != mask.length) return false
        return mask.indices.all { i ->
            when (mask[i].uppercaseChar()) {
                'D' -> reg[i].isDigit()
                'A' -> reg[i].isLetter()
                else -> true
            }
        }
    }

    private fun overMax(field: ExtractedField, max: Int?): String? {
        if (max == null || field.isEmpty) return null
        val v = field.value.trim().toIntOrNull() ?: return "Not a number"
        return if (v > max) "Above the maximum of $max" else null
    }
}
