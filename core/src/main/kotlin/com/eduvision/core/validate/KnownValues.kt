package com.eduvision.core.validate

import kotlin.math.max

/**
 * Values teachers confirmed for one written field of a layout (course name,
 * section, branch), with how many sheets each was confirmed on. A reading
 * close to one that repeats is offered as a one-tap suggestion; it is never
 * filled in silently, since "CSM-05" must not become "CSM-04".
 */
class KnownValues(private val counts: Map<String, Int>) {
    /**
     * The repeated value [reading] most likely is, or null: none close
     * enough, two equally close, or [reading] already is it.
     */
    fun suggest(reading: String): String? {
        val k = Text.key(reading)
        if (k.isEmpty()) return null
        val scored = counts.filter { it.value >= MIN_SHEETS }.keys
            .map { it to Text.editDistance(k, Text.key(it)) }
            .filter { (v, d) -> d <= max(2.0, MAX_SHARE * Text.key(v).length) }
            .sortedBy { it.second }
        val best = scored.firstOrNull() ?: return null
        if (scored.size > 1 && scored[1].second == best.second) return null
        return best.first.takeIf { it != reading.trim() }
    }

    companion object {
        /** Confirmed on this many sheets: a batch value, not one student's name. */
        const val MIN_SHEETS = 2

        /** Edits allowed, as a share of the remembered value's letters and digits. */
        const val MAX_SHARE = 0.4
    }
}
