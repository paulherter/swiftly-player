package de.paulherter.swiftly.rustcore.host

import java.io.File
import java.lang.reflect.Modifier
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A UI must never compare against a word the core does not send. `CoreWords` holds every word the Android UIs compare;
 * `crates/swiftly-uniffi/data/core-words.json` holds every word the core sends (written by the Rust test `core_words_contract`).
 * Every constant of every `CoreWords` group must be in its group of the file.
 */
class CoreWordsContractTest {
    private val file = generateSequence(File("").absoluteFile) { it.parentFile }
        .map { File(it, "crates/swiftly-uniffi/data/core-words.json") }
        .firstOrNull { it.isFile }

    private fun core(): JSONObject {
        val f = file ?: error("crates/swiftly-uniffi/data/core-words.json not found above ${File("").absolutePath}")
        return JSONObject(f.readText())
    }

    private fun sent(group: String): Set<String> {
        val list = core().optJSONArray(group) ?: error("core-words.json has no group $group")
        return (0 until list.length()).map { list.getString(it) }.toSet()
    }

    /** group name -> (constant name -> word), read from the `CoreWords` nested objects. */
    private fun compared(): Map<String, Map<String, String>> =
        CoreWords::class.java.declaredClasses.associate { group ->
            val strings = group.declaredFields.filter {
                Modifier.isStatic(it.modifiers) && it.type == String::class.java
            }.associate { it.name to it.get(null) as String }
            (strings["GROUP"] ?: error("${group.simpleName} has no GROUP")) to (strings - "GROUP")
        }

    @Test
    fun everyComparedWordIsSentByTheCore() {
        val missing = mutableListOf<String>()
        for ((group, words) in compared()) {
            val sent = sent(group)
            for ((name, word) in words) if (word !in sent) missing += "$group: $name = \"$word\" (core sends $sent)"
        }
        assertTrue("CoreWords compares against words the core never sends:\n" + missing.joinToString("\n"), missing.isEmpty())
    }

    @Test
    fun theWholeContractIsCovered() {
        // The check above must not pass because reflection found nothing.
        val groups = compared()
        assertTrue("CoreWords groups: ${groups.keys}", groups.size >= 7 && groups.values.all { it.isNotEmpty() })
    }
}
