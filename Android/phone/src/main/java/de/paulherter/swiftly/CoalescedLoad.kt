package de.paulherter.swiftly

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * One read at a time, run in [scope] (never in the caller's effect, whose cancellation would drop it). A request that
 * arrives while a read runs makes it run once more afterwards, with whatever the settings are then. Call from one thread.
 */
class CoalescedLoad(private val scope: CoroutineScope, private val read: suspend () -> Unit) {
    private var running = false
    private var again = false

    fun request() {
        if (running) { again = true; return }
        running = true
        scope.launch {
            try {
                do {
                    again = false
                    try { read() } catch (e: CancellationException) { throw e } catch (_: Exception) { }
                } while (again)
            } finally { running = false }
        }
    }
}
