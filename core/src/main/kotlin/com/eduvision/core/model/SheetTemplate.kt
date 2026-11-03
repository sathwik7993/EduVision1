package com.eduvision.core.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** What a template box contains. */
@Serializable
enum class FieldKind(val label: String) {
    REGISTRATION("Registration No"),
    PART_A("Part-A total"),
    PART_B("Part-B total"),
    QUESTION("Question mark"),

    /**
     * A total the examiner wrote (grand-total cell). Never used as the total,
     * only cross-checked against Part-A + Part-B.
     */
    WRITTEN_TOTAL("Grand total"),

    /** Any other number the teacher wants as a column ("Internal marks"). */
    MARK("Other number"),

    /** Any other writing the teacher wants as a column ("Name", "Branch"). */
    TEXT("Other text"),

    /** One of printed options ticked or circled ("B.Tech / M.Tech / MBA"). */
    CHOICE("Ticked option"),
}

/** A box normalised to the template's reference image (0..1 on both axes). */
@Serializable
data class NormBox(val left: Double, val top: Double, val right: Double, val bottom: Double) {
    val width get() = right - left
    val height get() = bottom - top
}

/** One field on the sheet. */
@Serializable
data class TemplateField(
    val kind: FieldKind,
    val box: NormBox,
    /**
     * Question label ("Q1", "3b"), or the column name of a MARK/TEXT field;
     * optional for the other kinds.
     */
    val label: String = "",
    /** Which part a question belongs to: "A" or "B". */
    val part: String = "A",
    val maxMarks: Int? = null,
    /**
     * Printed boxes in a comb (one character each), e.g. a registration
     * number; 0 for a single box. For the registration number the template's
     * mask, when set, fixes this to the mask's length.
     */
    val cells: Int = 0,
    /**
     * Written on a line or in open space, not inside a printed box: read
     * where it is, without snapping to a cell.
     */
    val free: Boolean = false,
    /** CHOICE: the printed options, and where each sits on the reference. */
    val options: List<String> = emptyList(),
    val optionBoxes: List<NormBox> = emptyList(),
) {
    val title: String
        get() = when {
            kind == FieldKind.QUESTION -> "${label.ifEmpty { "Question" }} (Part-$part)"
            label.isNotEmpty() && kind != FieldKind.QUESTION -> label
            else -> kind.label
        }
}

/**
 * Describes one exam-sheet layout.
 *
 * A template is a reference photo of the layout plus field boxes on it. Later
 * photos are registered onto the reference by matching image features, so no
 * text recognition runs on a normal scan. A new layout is set up from one
 * sample sheet: the app suggests fields from the printed labels
 * ([com.eduvision.core.recog.FieldSuggester]) and the teacher taps the boxes
 * they want ([com.eduvision.core.recog.CellFinder.boxAt]).
 */
@Serializable
data class SheetTemplate(
    val id: String,
    val name: String,
    val fields: List<TemplateField> = emptyList(),
    /** Grayscale reference image file name, relative to the template store. */
    val referenceImage: String? = null,
    /**
     * Character class per registration position: D digit, A letter, X either,
     * e.g. "DDADDADDXX" for 23H51A66K1. Its length is the number of comb cells.
     */
    val registrationMask: String? = null,
    val partAMax: Int = 40,
    val partBMax: Int = 60,
    /** Overrides the default "6-15 alphanumeric with at least two digits" rule. */
    val registrationPattern: String? = null,
    /** True when the boxes came from the printed labels, not from the teacher. */
    val auto: Boolean = false,
) {
    val registrationLength: Int? get() = registrationMask?.takeIf { it.isNotEmpty() }?.length

    fun field(kind: FieldKind) = fields.firstOrNull { it.kind == kind }

    fun toJson(): String = json.encodeToString(serializer(), this)

    companion object {
        val defaultRegistrationPattern = Regex("^(?=.*\\d.*\\d)[A-Z0-9]{6,15}$")
        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; prettyPrint = false }
        fun fromJson(text: String): SheetTemplate = json.decodeFromString(serializer(), text)
    }
}
