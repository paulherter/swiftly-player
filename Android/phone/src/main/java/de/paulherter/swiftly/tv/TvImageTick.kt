package de.paulherter.swiftly.tv

import android.app.Activity
import android.view.Display
import de.paulherter.swiftly.PlayerEngine
import kotlin.math.abs
import kotlin.math.roundToLong

/**
 * Mirrors `FrameTick` in `Sources/tvOS/FrameTick.swift`: match the TV's refresh rate to the file so
 * 23.976/24 fps films do not judder in 3:2 pulldown (24 does not divide 60; every frame is
 * alternately too short and too long). The reasoning there applies unchanged: no counter shows
 * anything because no frame is lost, only the display duration is uneven.
 *
 * Android has no `AVDisplayManager`. The counterpart is `Display.Mode` with
 * `WindowManager.LayoutParams.preferredDisplayModeId`: the same physical output switch as
 * `preferredDisplayCriteria` on tvOS, via window parameters instead of a dedicated manager.
 *
 * The rate is measured from VLC's own video track (`MediaPlayer.getCurrentVideoTrack()`), not
 * from server data before opening: the core facade does not yet deliver structured frame-rate or
 * codec data to Kotlin (only formatted text for the tech badge). The early path on tvOS only
 * avoids a visible flash behind the loading screen; here the late, safe path is enough. Measured
 * once, then remembered, as there.
 */
object TvImageTick {
    private var measured: Double? = null
    private var attempts = 0

    /** The mode that was set, for `resolve()`. `null` means nothing was set. */
    private var setMode: Int? = null

    /** The rate the output was switched to; `null` if no switch happened. */
    var demanded: Double? = null
        private set

    /** The frame rate of the running file, measured once from the engine (VLC's video track, or Media3's video format). Once is enough: a
         * file's frame rate does not change, and `getCurrentVideoTrack()` builds a fresh object on
         * every call. Up to 40 attempts, then give up (see `FrameTick.rate(from:)`). */
    fun rate(raw: Double?): Double? {
        measured?.let { return it }
        if (attempts >= 40) return null
        attempts++
        val rate = raw ?: return null
        if (rate <= 1 || rate >= 250) return null
        measured = rate
        return rate
    }

    /** Whether more measuring is pending; then the tick must leave VLC alone (same warning as
         * `FrameTick.stillPostMeasure` on tvOS: the video track is rebuilt on every access). */
    fun stillPostMeasure(): Boolean = measured == null && attempts < 40

    /**
         * Adopts the running file's frame rate as soon as VLC knows the video track. `allowed` comes
         * from outside (the "Bildrate anpassen" setting), same case split as
         * `FrameTick.userAllowed`.
         */
    fun adapt(activity: Activity, player: PlayerEngine, allowed: Boolean) {
        if (!stillPostMeasure()) return
        val rate = rate(player.frameRate()) ?: return
        setDown(activity, rate, allowed)
    }

    /** Whether the frame rate divides evenly into the current display mode (`FrameTick.passt`). */
    private fun fits(activity: Activity, rate: Double): Boolean {
        @Suppress("DEPRECATION")
        val tick = activity.windowManager.defaultDisplay.refreshRate.toDouble()
        if (tick < 1) return false
        val factor = tick / rate
        // 23.976 is not 24: use a small tolerance, or the most common film rate falls through.
        return abs(factor - factor.roundToLong()) < 0.01
    }

    private fun setDown(activity: Activity, rate: Double, allowed: Boolean) {
        // Do not switch when it gains nothing; every switch costs a few seconds of black screen.
        if (fits(activity, rate)) { demanded = null; return }
        if (!allowed) return

        @Suppress("DEPRECATION")
        val display = activity.windowManager.defaultDisplay
        @Suppress("DEPRECATION")
        val current = display.mode
        // Same physical mode (resolution), only with the refresh rate closest to the file's, so no
                // upscaling to another resolution on the side.
        @Suppress("DEPRECATION")
        val target = display.supportedModes
            .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
            .minByOrNull { abs(it.refreshRate - rate) }
            ?: return
        // No usable mode nearby: request nothing rather than a rate that does not divide evenly either.
        if (abs(target.refreshRate - rate) > 0.6) return
        if (setMode == target.modeId) { demanded = rate; return }

        val window = activity.window
        val parameter = window.attributes
        parameter.preferredDisplayModeId = target.modeId
        window.attributes = parameter
        setMode = target.modeId
        demanded = rate
    }

    /** Back to the mode used for the UI; only if something was actually set. */
    fun resolve(activity: Activity) {
        measured = null
        attempts = 0
        demanded = null
        if (setMode == null) return
        setMode = null
        val window = activity.window
        val parameter = window.attributes
        parameter.preferredDisplayModeId = 0
        window.attributes = parameter
    }
}
