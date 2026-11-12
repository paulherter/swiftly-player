package de.paulherter.swiftly.tv

/**
 * **What the TV detail row shows before "...":** "Watched" always, "Shuffle" on series, "Watch together" only
 * with a file (or an episode to continue) and the right to create a group. The "..." panel leaves these out, so
 * nothing is offered twice (same split as the Apple TV page).
 */
internal data class TvRowActions(val shuffle: Boolean, val together: Boolean) {
    companion object {
        fun forMovie(planPresent: Boolean, mayCreate: Boolean) = TvRowActions(shuffle = false, together = planPresent && mayCreate)
        fun forSeries(hasEpisodeToContinue: Boolean, mayCreate: Boolean) = TvRowActions(shuffle = true, together = hasEpisodeToContinue && mayCreate)
    }
}
