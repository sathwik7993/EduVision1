package com.eduvision.core.model

/**
 * One value read from the sheet, with how much the recognizer trusts it.
 * Anything below [TRUSTED_ABOVE], or with an [issue], goes to review.
 */
data class ExtractedField(
    val value: String,
    /** 0.0 - 1.0: the least certain character (one doubtful digit makes the mark doubtful). */
    val confidence: Double,
    /** What the model read before positional repair, for the review screen. */
    val rawText: String? = null,
    /** Typed or confirmed by the teacher: authoritative. */
    val edited: Boolean = false,
    /** Why validation doubts this value. A flagged value always goes to review. */
    val issue: String? = null,
    /** A likely correction, e.g. the closest roster entry. */
    val suggestion: String? = null,
    /** PNG of the exact pixels the model read. */
    val crop: ByteArray? = null,
    /**
     * The same reading with each easily confused character (0/D, 1/I, 5/S...)
     * swapped where the format allows either; null when there is none. Lets a
     * roster settle "23H51A6609" vs "23H51A66D9".
     */
    val alternative: String? = null,
) {
    val isEmpty get() = value.isBlank()
    val needsReview get() = !edited && (isEmpty || confidence < TRUSTED_ABOVE || issue != null)

    fun withIssue(newIssue: String?, newSuggestion: String? = null): ExtractedField {
        // Re-validating must not stack duplicates; a teacher's value is final.
        if (newIssue == null || edited || issue?.contains(newIssue) == true) return this
        return copy(
            issue = if (issue == null) newIssue else "$issue; $newIssue",
            suggestion = newSuggestion ?: suggestion,
        )
    }

    override fun equals(other: Any?) = other is ExtractedField && value == other.value &&
        confidence == other.confidence && rawText == other.rawText && edited == other.edited &&
        issue == other.issue && suggestion == other.suggestion && crop.contentEquals(other.crop) &&
        alternative == other.alternative

    override fun hashCode() = listOf(value, confidence, rawText, edited, issue, suggestion).hashCode()

    companion object {
        /**
         * Review gate for marks. 0.90 since the v4 model read "10" as "20" at
         * 0.88 on real sheets (docs/PROGRESS.md).
         */
        const val TRUSTED_ABOVE = 0.90
        val EMPTY = ExtractedField("", 0.0)

        /** A field this layout does not have: nothing to read or review. */
        val NOT_ON_SHEET = ExtractedField("", 1.0, edited = true)
        fun manual(value: String, crop: ByteArray? = null) =
            ExtractedField(value, 1.0, edited = true, crop = crop)
    }
}

/** A per-question mark or a total the examiner wrote. */
data class LabelledMark(
    val label: String,
    /** "A" or "B" for a question; empty for a written total. */
    val part: String,
    val field: ExtractedField,
    val maxMarks: Int? = null,
) {
    val value get() = field.value.trim().toIntOrNull() ?: 0

    /** A confidently blank cell is normal: examiners often fill only the totals. */
    val needsReview get() = !field.edited &&
        (field.issue != null || field.confidence < ExtractedField.TRUSTED_ABOVE)
}

/** One scanned sheet, before it is committed to the workbook. */
data class ScanResult(
    val registrationNo: ExtractedField,
    val partA: ExtractedField,
    val partB: ExtractedField,
    val questions: List<LabelledMark> = emptyList(),
    val writtenTotals: List<LabelledMark> = emptyList(),
    /** The teacher's own fields (MARK / TEXT kinds), one column each. */
    val extras: List<LabelledMark> = emptyList(),
    val imagePath: String? = null,
    /** How the photo was registered onto the template, for the review screen. */
    val alignment: String = "",
    /** Per-stage latency in ms, so speed on a device is measured, not assumed. */
    val timingsMs: Map<String, Long> = emptyMap(),
    /** Per-field alignment details ("partA" -> "context 0.83"), for the review screen. */
    val diagnostics: Map<String, String> = emptyMap(),
) {
    val partAValue get() = partA.value.trim().toIntOrNull() ?: 0
    val partBValue get() = partB.value.trim().toIntOrNull() ?: 0

    /** Always derived: trusting a handwritten total would let paper arithmetic errors in. */
    val total get() = partAValue + partBValue

    val isReadyToSave
        get() = !registrationNo.needsReview && !partA.needsReview && !partB.needsReview &&
            (questions + writtenTotals + extras).none { it.needsReview } && registrationNo.value.isNotBlank()

    val fieldsNeedingReview: List<String>
        get() = buildList {
            if (registrationNo.needsReview) add("Registration No")
            if (partA.needsReview) add("Part-A")
            if (partB.needsReview) add("Part-B")
            (questions + writtenTotals + extras).filter { it.needsReview }.forEach { add(it.label) }
        }
}
