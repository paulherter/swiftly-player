package de.paulherter.swiftly

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

/** The Start page's Seerr read (`SeerrHomeFlow.load`) must survive its caller being cancelled (a changed effect key). */
class CoalescedLoadTest {
    private val own = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)

    @Test fun aCancelledCallerDoesNotKillTheReadNorTheFollowUp() = runBlocking {
        val reads = AtomicInteger()
        val gate = CompletableDeferred<Unit>()
        val finished = CompletableDeferred<Unit>()
        val load = CoalescedLoad(own) { if (reads.incrementAndGet() == 1) gate.await() else finished.complete(Unit) }
        // The page's first effect asks, runs the read, and is then cancelled by a key change; the new effect asks again.
        val effect = launch(start = CoroutineStart.UNDISPATCHED) { load.request(); gate.await() }
        load.request()
        effect.cancelAndJoin()
        gate.complete(Unit)
        withTimeout(2000) { finished.await() }
        assertEquals(2, reads.get())
    }

    @Test fun requestsDuringARunCollapseToOneMoreRead() = runBlocking {
        val reads = AtomicInteger()
        val gate = CompletableDeferred<Unit>()
        val done = CompletableDeferred<Unit>()
        val load = CoalescedLoad(own) { if (reads.incrementAndGet() == 1) gate.await() else done.complete(Unit) }
        load.request(); load.request(); load.request()
        gate.complete(Unit)
        withTimeout(2000) { done.await() }
        assertEquals(2, reads.get())
    }

    @Test fun aFailedReadDoesNotBlockTheNextRequest() = runBlocking {
        val reads = AtomicInteger()
        val done = CompletableDeferred<Unit>()
        val load = CoalescedLoad(own) { if (reads.incrementAndGet() == 1) error("offline") else done.complete(Unit) }
        load.request()
        load.request()
        withTimeout(2000) { done.await() }
        assertEquals(2, reads.get())
    }
}
