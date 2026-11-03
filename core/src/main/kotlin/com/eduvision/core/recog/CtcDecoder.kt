package com.eduvision.core.recog

import kotlin.math.min

/** Class i+1 is CHARSET[i]; must match CHARSET in training/recognizer. */
const val CHARSET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
const val DIGITS = "0123456789"
const val LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

data class Reading(
    val text: String,
    /** Minimum per-character probability. */
    val confidence: Double,
    /** Best character of another allowed class at the same frames, per character. */
    val runnerUp: List<Pair<Char, Double>> = emptyList(),
)

/**
 * Greedy CTC decoding restricted to the characters a field may contain.
 *
 * Confidence is the model's raw probability, not renormalised over the
 * allowed classes: if the model put 60% on "S", the "5" chosen in its place is
 * only ~35% certain, and that doubt must reach the review gate. It is also
 * capped by the strongest disallowed character the model preferred.
 */
object CtcDecoder {
    fun decode(p: Probs, allowed: String = CHARSET): Reading {
        val keep = intArrayOf(0) + allowed.map { CHARSET.indexOf(it) + 1 }.filter { it > 0 }
        val allowedSet = keep.toHashSet()
        val text = StringBuilder()
        val confs = ArrayList<Double>()
        val spans = ArrayList<MutableList<Int>>()
        var prev = 0
        var minBlank = 1.0
        var dropped = 0.0
        for (t in 0 until p.frames) {
            var best = 0
            var bestP = -1f
            for (j in keep.indices) {
                val v = p[t, keep[j]]
                if (v > bestP) { bestP = v; best = j }
            }
            minBlank = min(minBlank, p[t, 0].toDouble())
            for (c in 1 until p.classes) {
                val v = p[t, c]
                if (v > dropped && v > bestP && c !in allowedSet) dropped = v.toDouble()
            }
            if (best != 0 && best != prev) {
                text.append(CHARSET[keep[best] - 1]); confs += bestP.toDouble(); spans += mutableListOf(t)
            } else if (best != 0) {
                spans.last() += t
                if (bestP > confs.last()) confs[confs.size - 1] = bestP.toDouble()
            }
            prev = best
        }
        if (confs.isEmpty()) {
            // An empty box is only as trustworthy as its least certain blank frame.
            return Reading("", if (p.frames == 0) 0.0 else min(minBlank, 1 - dropped))
        }
        val runnerUp = text.indices.map { i ->
            var bc = '?'
            var bp = 0.0
            for (t in spans[i]) for (j in 1 until keep.size) {
                val ch = CHARSET[keep[j] - 1]
                if (ch == text[i]) continue
                val v = p[t, keep[j]].toDouble()
                if (v > bp) { bp = v; bc = ch }
            }
            bc to bp
        }
        return Reading(text.toString(), min(confs.min(), 1 - dropped), runnerUp)
    }

    fun allowedFor(maskChar: Char?): String = when (maskChar?.uppercaseChar()) {
        'D' -> DIGITS
        'A' -> LETTERS
        else -> CHARSET
    }
}
