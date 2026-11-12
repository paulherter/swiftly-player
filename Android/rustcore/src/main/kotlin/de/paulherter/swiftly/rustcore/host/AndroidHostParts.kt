package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.DateText
import de.paulherter.swiftly.rustcore.PlayerEngine
import de.paulherter.swiftly.rustcore.PlayerGroupHook
import de.paulherter.swiftly.rustcore.PlexPinListener
import de.paulherter.swiftly.rustcore.QuickConnectListener
import de.paulherter.swiftly.rustcore.RemoteEvent
import de.paulherter.swiftly.rustcore.RemoteListener
import de.paulherter.swiftly.rustcore.SeerrCookieJar
import de.paulherter.swiftly.rustcore.StreamForwardHost
import de.paulherter.swiftly.rustcore.SyncPlayHost
import de.paulherter.swiftly.rustcore.SyncPlayStep
import java.security.SecureRandom
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

/**
 * `DateText`: the long date of an ISO timestamp from the server in the device's language
 * (`date.formatted(date: .long)` on Apple: "1. Mai 1980"). The timestamp is read as UTC, as the server writes it, and
 * shown as that calendar day, so a birthday never moves with the time zone.
 */
class AndroidDateText(private val locale: () -> Locale = { Locale.getDefault() }) : DateText {
    override fun longDate(iso: String): String? {
        val day = parse(iso.trim()) ?: return null
        return DateTimeFormatter.ofLocalizedDate(FormatStyle.LONG).withLocale(locale()).format(day)
    }

    private fun parse(s: String): LocalDate? = runCatching { OffsetDateTime.parse(s).withOffsetSameInstant(ZoneOffset.UTC).toLocalDate() }.getOrNull()
        ?: runCatching { Instant.parse(s).atOffset(ZoneOffset.UTC).toLocalDate() }.getOrNull()
        ?: runCatching { LocalDateTime.parse(s).toLocalDate() }.getOrNull()
        ?: runCatching { LocalDate.parse(s.take(10)) }.getOrNull()
}

/**
 * `SeerrCookieJar`. The core takes the session cookie from `Set-Cookie` of the sign-in answer first; the jar is the
 * fallback for servers that set it on a redirect hop. [AndroidHttpClient] does not keep cookies (a hop is followed by
 * hand), so this is a plain in-memory table the app may feed with [remember]; without a cookie the answer is `null`,
 * which the core handles.
 */
class AndroidSeerrCookieJar : SeerrCookieJar {
    private val cookies = ConcurrentHashMap<String, String>()
    fun remember(address: String, cookie: String) { cookies[address] = cookie }
    override fun sessionCookie(address: String): String? = cookies[address]
    override fun forget(address: String) { cookies.remove(address) }
}

/**
 * `StreamForwardHost`: the port of the app's local forwarding service (`StreamForwarder.currentPort`, 0 while it does
 * not run) and 16 bytes from the OS random source.
 */
class AndroidStreamForwardHost(private val port: () -> Int, private val random: SecureRandom = SecureRandom()) : StreamForwardHost {
    override fun listeningPort(): UShort? = port().takeIf { it in 1..65535 }?.toUShort()
    override fun randomBytes(): ByteArray = ByteArray(16).also { random.nextBytes(it) }
}

/**
 * `SyncPlayHost` over the core's own player engine: the group moves the player through the same commands the player
 * screen uses, a title switch goes to [load] (the screen opens it and reports `title_load_failed` if it cannot play).
 * Commands return at once; nothing here blocks the core's thread.
 */
class EngineSyncPlayHost(private val engine: PlayerEngine, private val load: (title: String, since: Double) -> Unit) : SyncPlayHost {
    override fun playerStep(step: SyncPlayStep) {
        when (step) {
            SyncPlayStep.Proceed -> engine.play()
            SyncPlayStep.Halt -> engine.pause()
            is SyncPlayStep.Jump -> engine.seek(step.seconds)
        }
    }
    override fun loadTitle(title: String, since: Double) = load(title, since)
}

/** `PlayerGroupHook`: what the player's own buttons mean in a SyncPlay group (the screen forwards them to the session). */
class LambdaGroupHook(private val onToggle: (Boolean) -> Unit, private val onJump: (Double) -> Unit) : PlayerGroupHook {
    override fun toggle(running: Boolean) = onToggle(running)
    override fun jump(to: Double) = onJump(to)
}

/** The seconds left of a QuickConnect code, once a second. */
class LambdaQuickConnectListener(private val f: (Long) -> Unit) : QuickConnectListener { override fun rest(seconds: Long) = f(seconds) }

/** The seconds left of a Plex PIN, once a second. */
class LambdaPlexPinListener(private val f: (Long) -> Unit) : PlexPinListener { override fun rest(seconds: Long) = f(seconds) }

/**
 * `RemoteListener`: events of the control channel. Called from the channel's task, so it must not block; [onConnected]
 * is where the app sends `POST Sessions/Capabilities/Full`.
 */
class LambdaRemoteListener(private val onEvent: (RemoteEvent) -> Unit, private val onConnected: () -> Unit) : RemoteListener {
    override fun event(event: RemoteEvent) = onEvent(event)
    override fun connected() = onConnected()
}
