package com.eduvision.core.validate

/**
 * The registration numbers of one class, imported from the college's list.
 * Used only to check readings; it never leaves the device.
 */
class Roster(registrations: Iterable<String>) {
    val registrations: Set<String> = registrations.map(Text::cleanRegistration).filter { it.isNotEmpty() }.toSet()

    val isEmpty get() = registrations.isEmpty()

    operator fun contains(reg: String) = Text.cleanRegistration(reg) in registrations

    /**
     * The entry within [maxEdits] edits of [reg], or null when there is none or
     * the nearest is ambiguous: two students one digit apart must not be
     * "corrected" into each other.
     */
    fun closest(reg: String, maxEdits: Int = 2): String? {
        val needle = Text.cleanRegistration(reg)
        if (needle.isEmpty()) return null
        var best: String? = null
        var bestD = maxEdits + 1
        var tie = false
        for (c in registrations) {
            val d = Text.editDistance(needle, c)
            if (d < bestD) { best = c; bestD = d; tie = false } else if (d == bestD) tie = true
        }
        return if (tie) null else best
    }

    companion object {
        val EMPTY = Roster(emptyList())
        private val headerPattern = Regex("\\b(reg|regd|registration|registered|roll|hall|id|htno)\\b")

        /**
         * Picks the registration column from spreadsheet rows: the column whose
         * header mentions reg/roll/hall ticket/id, else the first column.
         */
        fun fromRows(rows: List<List<String>>): Roster {
            if (rows.isEmpty()) return EMPTY
            var column = 0
            var start = 0
            rows.first().forEachIndexed { c, cell ->
                val label = cell.lowercase().replace(Regex("[^a-z0-9]+"), " ").trim()
                if (start == 0 && headerPattern.containsMatchIn(label)) { column = c; start = 1 }
            }
            val regs = rows.drop(start).mapNotNull { row ->
                val v = Text.cleanRegistration(row.getOrNull(column) ?: return@mapNotNull null)
                // Skips a header that did not match, blank rows and serial numbers.
                v.takeIf { it.length >= 4 && it.any(Char::isDigit) }
            }
            return Roster(regs)
        }
    }
}
