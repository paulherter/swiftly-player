package de.paulherter.swiftly.support

/**
 * **Keeps a supporter key and the status it grants up to date.** Direct build only; the Kotlin
 * twin of `SupporterKeyKeeper` in the package's SupportKeyKit, with the same rules and the same
 * tests (`SupporterKeyKeeperTest`).
 *
 * - `activate` checks a pasted key, stores it, grants the status and the plan.
 * - `applyExpiry` (every start) withdraws the status when a monthly key ran out, and grants it
 *   again when the stored key counts again. The key stays stored. Statuses from a store are untouched.
 * - `refreshIfDue` asks the shop, at most every 12 hours from the expiry day minus 10 days
 *   (monthly) or every 30 days (lifetime, for refunds), whether the licence still runs. It sends
 *   only the random licence number. A renewed monthly key replaces the stored one; a refunded
 *   licence removes it. Network errors change nothing.
 */
class SupporterKeyKeeper(
    private val storage: Storage,
    private val sink: Sink,
    private val publicKey: ByteArray = SupporterKeyCheck.publicKey,
    private val app: Int = SupporterKeyCheck.APP_SWIFTLY,
    private val allowTestKeys: Boolean = false,
    /** Posts the form body and returns status and text; null when the network fails. */
    private val post: (String) -> Pair<Int, String>? = ::postToShop,
) {
    /** Two small strings that survive restarts (`SharedPreferences` through `app.store`). */
    interface Storage {
        fun get(key: String): String?
        fun set(key: String, value: String?)
    }

    /** What the keeper changes in the app. */
    interface Sink {
        /** A key counts: grant the status (`fresh`: pasted just now, so say thanks). */
        fun grant(license: SupporterKeyCheck.License, fresh: Boolean)
        /** The key stopped counting (expired or refunded): withdraw a status that came from a key. */
        fun withdraw()
        /** True when the current status is none or came from a key, never from a store. */
        fun mayTouchStatus(): Boolean
    }

    enum class Refresh { NotDue, Unchanged, Renewed, Ended, Revoked, Failed }

    val storedKey: String? get() = storage.get(KEY)

    /** The stored key, read without the expiry check. */
    val license: SupporterKeyCheck.License?
        get() = storedKey?.let { (read(it) as? SupporterKeyCheck.Read.Ok)?.license }

    fun activate(text: String, nowMs: Long = System.currentTimeMillis()): SupporterKeyCheck.Result {
        val result = SupporterKeyCheck.verify(text, publicKey, app, allowTestKeys, nowMs)
        if (result !is SupporterKeyCheck.Result.Valid) return result
        val license = (read(text) as? SupporterKeyCheck.Read.Ok)?.license ?: return result
        save(text.trim(), license, nowMs, fresh = true)
        return result
    }

    fun applyExpiry(nowMs: Long = System.currentTimeMillis()) {
        val license = license ?: return
        if (!sink.mayTouchStatus()) return
        if (license.isActive(nowMs)) sink.grant(license, fresh = false) else sink.withdraw()
    }

    fun refreshIfDue(nowMs: Long = System.currentTimeMillis()): Refresh {
        val current = license
        if (current == null || !isDue(current, nowMs)) return Refresh.NotDue
        val (status, body) = post("id=${current.id}") ?: return Refresh.Failed
        if (status != 200) return Refresh.Failed
        val state = field(body, "state") ?: return Refresh.Failed
        markChecked(nowMs)
        when (state) {
            "active" -> {
                val text = field(body, "key") ?: return Refresh.Unchanged
                val fresh = (read(text) as? SupporterKeyCheck.Read.Ok)?.license ?: return Refresh.Unchanged
                if (fresh.app != current.app || fresh.id != current.id) return Refresh.Unchanged
                if ((fresh.expiresAtMs ?: Long.MAX_VALUE) < (current.expiresAtMs ?: Long.MAX_VALUE)) return Refresh.Unchanged
                if (text == storedKey) { applyExpiry(nowMs); return Refresh.Unchanged }
                save(text, fresh, nowMs, fresh = false)
                return Refresh.Renewed
            }
            "ended" -> { applyExpiry(nowMs); return Refresh.Ended }  // runs out on its own expiry day
            "revoked" -> {
                storage.set(KEY, null)
                if (sink.mayTouchStatus()) sink.withdraw()
                return Refresh.Revoked
            }
            else -> return Refresh.Unchanged
        }
    }

    internal fun isDue(license: SupporterKeyCheck.License, nowMs: Long): Boolean {
        val last = storage.get(CHECKED)?.toLongOrNull()?.times(1000) ?: Long.MIN_VALUE / 2
        license.expiresAtMs?.let { return nowMs >= it - RENEW_WINDOW && nowMs - last >= MONTHLY_INTERVAL }
        return nowMs - last >= LIFETIME_INTERVAL
    }

    private fun markChecked(nowMs: Long) = storage.set(CHECKED, (nowMs / 1000).toString())

    private fun read(text: String) = SupporterKeyCheck.read(text, publicKey, app, allowTestKeys)

    private fun save(text: String, license: SupporterKeyCheck.License, nowMs: Long, fresh: Boolean) {
        storage.set(KEY, text)
        // A fresh key counts as checked: no request right after pasting.
        markChecked(nowMs)
        if (license.isActive(nowMs)) sink.grant(license, fresh) else sink.withdraw()
    }

    /** The shop answers `{"state":"active","key":"SS2-…"}`; keys are Base32, so a plain scan is enough. */
    private fun field(json: String, name: String): String? =
        Regex(""""$name"\s*:\s*"([^"\\]*)"""").find(json)?.groupValues?.get(1)

    companion object {
        /** `SupporterKeyKeeper.keyStorageKey` / `checkedStorageKey` in the package. Never change. */
        const val KEY = "support.key"
        const val CHECKED = "support.keyChecked"
        const val RENEW_WINDOW = 10 * 86_400_000L
        const val MONTHLY_INTERVAL = 12 * 3_600_000L
        const val LIFETIME_INTERVAL = 30 * 86_400_000L
        /** `DirectSupport.licenseURL`. */
        const val LICENSE_URL = "https://pay.paulherter.de/license"

        /** One short POST, no cookies, no cache; the licence number is all that leaves the device. */
        fun postToShop(body: String): Pair<Int, String>? = runCatching {
            val c = java.net.URL(LICENSE_URL).openConnection() as java.net.HttpURLConnection
            try {
                c.requestMethod = "POST"
                c.connectTimeout = 20_000; c.readTimeout = 20_000
                c.useCaches = false; c.doOutput = true
                c.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
                c.outputStream.use { it.write(body.toByteArray()) }
                val code = c.responseCode
                val stream = if (code in 200..299) c.inputStream else c.errorStream
                code to (stream?.bufferedReader()?.use { it.readText() }.orEmpty())
            } finally { c.disconnect() }
        }.getOrNull()
    }
}
