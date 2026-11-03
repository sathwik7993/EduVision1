package com.eduvision.core.validate

/** String helpers shared by validation and layout finding. */
object Text {
    /** Lowercase letters and digits only: "Part-A Total:" -> "partatotal". */
    fun key(input: String) = input.lowercase().filter { it in 'a'..'z' || it in '0'..'9' }

    /** Uppercase, alphanumeric only. */
    fun cleanRegistration(token: String) = token.uppercase().filter { it in 'A'..'Z' || it in '0'..'9' }

    fun editDistance(a: String, b: String): Int {
        if (a == b) return 0
        if (a.isEmpty()) return b.length
        if (b.isEmpty()) return a.length
        var prev = IntArray(b.length + 1) { it }
        var cur = IntArray(b.length + 1)
        for (i in a.indices) {
            cur[0] = i + 1
            for (j in b.indices) {
                val cost = if (a[i] == b[j]) 0 else 1
                cur[j + 1] = minOf(cur[j] + 1, prev[j + 1] + 1, prev[j] + cost)
            }
            val t = prev; prev = cur; cur = t
        }
        return prev[b.length]
    }
}
