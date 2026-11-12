package de.paulherter.swiftly.rustcore.host

import de.paulherter.swiftly.rustcore.AccountRef
import de.paulherter.swiftly.rustcore.Core
import de.paulherter.swiftly.rustcore.PlayerSection
import java.net.HttpURLConnection

/**
 * [DownloadHooks] over the Rust core: the file address comes from `Core.downloadAddress` (the one rule set of the
 * desktop and Apple hosts, replacing `Kern.downloadAddress`), the server's own headers and the failure sentence come
 * from the app. Intro/outro sections, external subtitles and the successor lookup are server requests the app supplies
 * while their core models are not wired (`null`/no-op answers make the core ask again on the next contact, exactly as
 * the old manager did without a response).
 */
class CoreDownloadHooks(
    private val core: Core,
    private val account: () -> AccountRef?,
    private val locale: String,
    private val headers: (HttpURLConnection) -> Unit,
    private val sentence: (status: Int?, error: Throwable?) -> String,
    private val sections: suspend (String) -> List<PlayerSection>? = { null },
    private val subtitles: suspend (String, String?) -> Unit = { _, _ -> },
    private val successor: suspend (String, String) -> Pair<ByteArray, String?>? = { _, _ -> null },
) : DownloadHooks {
    override suspend fun address(id: String, source: String?, quality: String, audioIndex: Int?): String {
        val a = account() ?: error("not signed in")
        return core.downloadAddress(a, locale, id, source, quality, audioIndex?.toLong())
    }
    override suspend fun subtitles(id: String, source: String?) = subtitles.invoke(id, source)
    override suspend fun sections(id: String): List<PlayerSection>? = sections.invoke(id)
    override suspend fun successor(id: String, seriesId: String): Pair<ByteArray, String?>? = successor.invoke(id, seriesId)
    override fun prepare(connection: HttpURLConnection) = headers(connection)
    override fun failureText(status: Int?, error: Throwable?): String = sentence(status, error)
}
