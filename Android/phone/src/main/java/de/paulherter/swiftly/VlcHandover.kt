package de.paulherter.swiftly

/**
 * **Handing over to VLC after Media3** as pure rules, testable without a device (`VlcHandoverTest`).
 * The order is fixed: on the main thread Media3 comes down and VLC's views are attached (`PlayerEngine.vlcViewsAttach`),
 * then the open goes to the VLC thread, which plays and finally applies the speed.
 */
object VlcHandover {
    /** VLC's views must be attached when there is a layout and they are not (Media3 detached them). */
    fun attachNeeded(hasLayout: Boolean, attached: Boolean): Boolean = hasLayout && !attached

    /** The speed to set once VLC plays, `null` if it is already right (1x is VLC's default). */
    fun rateAfterOpen(tempo: Float): Float? = tempo.takeIf { it > 0f && it != 1f }
}
