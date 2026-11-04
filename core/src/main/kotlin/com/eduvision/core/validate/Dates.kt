package com.eduvision.core.validate

import java.time.DateTimeException
import java.time.LocalDate

/**
 * Handwritten dates as read by the text model: day first (Indian forms),
 * any of / - . or spaces between the parts, or none (ddmmyy, ddmmyyyy).
 */
object Dates {
    /** Letters a recogniser gives for handwritten digits. */
    private val lookAlike = mapOf(
        'O' to '0', 'o' to '0', 'D' to '0', 'Q' to '0', 'I' to '1', 'l' to '1', 'i' to '1', '|' to '1',
        '!' to '1', 'Z' to '2', 'z' to '2', 'S' to '5', 's' to '5', 'B' to '8', 'G' to '6', 'b' to '6',
        'g' to '9', 'q' to '9',
    )
    private const val SEPARATORS = "/-.\\, "

    /** A date-shaped reading, as written ([value]) and as "dd/mm/yyyy" ([canonical]). */
    data class Parsed(val date: LocalDate, val canonical: String, val neededLookAlikes: Boolean)

    /**
     * The date [reading] most plausibly is, or null when it cannot be a real
     * date within [yearsBack] years before [today] (or next year).
     */
    fun parse(reading: String, today: LocalDate = LocalDate.now(), yearsBack: Int = 5): Parsed? {
        val s = reading.trim()
        if (s.isEmpty()) return null
        var swapped = false
        val mapped = s.map { c ->
            when {
                c.isDigit() || c in SEPARATORS -> c
                c in lookAlike -> { swapped = true; lookAlike.getValue(c) }
                else -> return null
            }
        }.joinToString("")
        val groups = mapped.split(*SEPARATORS.toCharArray()).filter { it.isNotEmpty() }
        val (d, m, y) = when {
            groups.size == 3 -> Triple(groups[0], groups[1], groups[2])
            groups.size == 1 && groups[0].length == 6 -> groups[0].let { Triple(it.take(2), it.substring(2, 4), it.takeLast(2)) }
            groups.size == 1 && groups[0].length == 8 -> groups[0].let { Triple(it.take(2), it.substring(2, 4), it.takeLast(4)) }
            else -> return null
        }
        if (d.length > 2 || m.length > 2 || (y.length != 2 && y.length != 4)) return null
        val year = if (y.length == 2) 2000 + y.toInt() else y.toInt()
        if (year < today.year - yearsBack || year > today.year + 1) return null
        val date = try { LocalDate.of(year, m.toInt(), d.toInt()) } catch (_: DateTimeException) { return null }
        return Parsed(date, "%02d/%02d/%04d".format(date.dayOfMonth, date.monthValue, date.year), swapped)
    }

    /** Field labels that hold a date: "Date", "Date of Exam", "Exam date". */
    fun isDateField(label: String) = Text.key(label).let { it.contains("date") && !it.contains("candidate") }
}
