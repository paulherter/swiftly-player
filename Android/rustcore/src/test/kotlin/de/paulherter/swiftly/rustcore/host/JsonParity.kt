package de.paulherter.swiftly.rustcore.host

import org.json.JSONArray
import org.json.JSONObject

/**
 * Structural comparison of two JSON documents, old facade answer against new adapter answer: same keys, same
 * order of arrays, equal strings and booleans, numbers equal within 1e-6 (the old side wrote Doubles from Swift, the
 * new one from Rust). Returns the first difference as a path, or `null` if they are the same.
 */
object JsonParity {
    fun diff(old: String, new: String): String? = diff(parse(old), parse(new), "$")

    private fun parse(text: String): Any = text.trim().let { if (it.startsWith("[")) JSONArray(it) else JSONObject(it) }

    private fun diff(a: Any?, b: Any?, path: String): String? {
        if (a is JSONObject && b is JSONObject) {
            val ka = a.keys().asSequence().toSet(); val kb = b.keys().asSequence().toSet()
            (ka - kb).firstOrNull()?.let { return "$path.$it missing in new (old: ${short(a.get(it))})" }
            (kb - ka).firstOrNull()?.let { return "$path.$it extra in new (new: ${short(b.get(it))})" }
            for (k in ka.sorted()) diff(a.get(k), b.get(k), "$path.$k")?.let { return it }
            return null
        }
        if (a is JSONArray && b is JSONArray) {
            if (a.length() != b.length()) return "$path length old ${a.length()} new ${b.length()}"
            for (i in 0 until a.length()) diff(a.get(i), b.get(i), "$path[$i]")?.let { return it }
            return null
        }
        if (a is Number && b is Number) return if (Math.abs(a.toDouble() - b.toDouble()) <= 1e-6) null else "$path old $a new $b"
        return if (a == b) null else "$path old ${short(a)} new ${short(b)}"
    }

    private fun short(x: Any?) = x.toString().take(120)
}
