package de.paulherter.swiftly

import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import de.paulherter.swiftly.rustcore.BadgeKind
import de.paulherter.swiftly.rustcore.LibraryFailure
import de.paulherter.swiftly.rustcore.ListLoad
import de.paulherter.swiftly.rustcore.OwnHeader
import de.paulherter.swiftly.rustcore.PrimaryKind
import de.paulherter.swiftly.rustcore.RequestPill
import de.paulherter.swiftly.rustcore.SeerrBadge
import de.paulherter.swiftly.rustcore.SeerrConnection
import de.paulherter.swiftly.rustcore.SeerrDiscoverRails
import de.paulherter.swiftly.rustcore.SeerrHomeInfo
import de.paulherter.swiftly.rustcore.SeerrHub
import de.paulherter.swiftly.rustcore.SeerrLibrary
import de.paulherter.swiftly.rustcore.SeerrListsScreen
import de.paulherter.swiftly.rustcore.SeerrRequestRow
import de.paulherter.swiftly.rustcore.SeerrRequestsInfo
import de.paulherter.swiftly.rustcore.SeerrSeasonRowInfo
import de.paulherter.swiftly.rustcore.SeerrSheetInfo
import de.paulherter.swiftly.rustcore.SeerrTileCard
import de.paulherter.swiftly.rustcore.SeerrArrival
import de.paulherter.swiftly.rustcore.SeerrTitleScreen
import de.paulherter.swiftly.rustcore.SeerrRequestResult
import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.PrimaryButton
import de.paulherter.swiftly.shared.Strength
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Texts
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/**
 * The shared core's Seerr screens over the stored connection (`SeerrModel.hub` on Apple): one hub per stored
 * access, the screens share it. Everything here is the core's: the words, the quota, the states. The host only
 * keeps the stored access and answers the two library questions ([AndroidSeerrLibrary]).
 * Call from a background thread: the first call builds the core.
 */
class SeerrScreens(private val app: SwiftlyApplication) {
    private var access: String? = null
    private var hubValue: SeerrHub? = null
    private var listsValue: SeerrListsScreen? = null
    val library = AndroidSeerrLibrary(app)

    @Synchronized private fun renew() {
        val now = app.seerrStored()
        if (hubValue != null && now == access) return
        access = now
        val connection = now?.let { connectionOf(it) }
        val model = connection?.let { app.rk.core().seerrModel(it, null) }
        val hub = SeerrHub(model, Texts.language, library)
        hubValue = hub
        listsValue = SeerrListsScreen(hub)
    }

    fun hub(): SeerrHub { renew(); return hubValue!! }
    fun lists(): SeerrListsScreen { renew(); return listsValue!! }
    fun title(art: String, tmdb: Long) = SeerrTitleScreen(hub(), art, tmdb)

    companion object {
        /** The stored access (`{"adresse","keks","koepfe":[{"name","wert"}]}`) as the core's connection. */
        fun connectionOf(access: String): SeerrConnection? = runCatching {
            val o = JSONObject(access)
            val heads = o.optJSONArray("koepfe") ?: JSONArray()
            SeerrConnection(o.getString("adresse"), o.optString("keks"),
                (0 until heads.length()).map { heads.getJSONObject(it).let { h -> OwnHeader(h.getString("name"), h.getString("wert")) } })
        }.getOrNull()

        /** The access to store for a connection the core handed back. */
        fun accessOf(c: SeerrConnection): String = JSONObject().put("adresse", c.address).put("keks", c.cookie)
            .apply { if (c.headers.isNotEmpty()) put("koepfe", JSONArray(c.headers.map { JSONObject().put("name", it.name).put("wert", it.value) })) }.toString()

        fun headersOf(json: String): List<OwnHeader> = runCatching {
            val a = JSONArray(json); (0 until a.length()).map { a.getJSONObject(it).let { h -> OwnHeader(h.getString("name"), h.getString("wert")) } }
        }.getOrDefault(emptyList())
    }
}

/** The Jellyfin side of the Seerr screens (`JellyfinSeerrLibrary` on Apple): which library item has a TMDB id; "scan again". */
class AndroidSeerrLibrary(private val app: SwiftlyApplication) : SeerrLibrary {
    private fun session(): JSONObject? = app.store.accounts?.let { KernRules.bundleActive(it) }?.let { runCatching { JSONObject(it) }.getOrNull() }

    private fun call(method: String, path: String): JSONObject? {
        val s = session() ?: return null
        val c = java.net.URL(s.optString("serverURL").trimEnd('/') + path).openConnection() as java.net.HttpURLConnection
        c.requestMethod = method; c.connectTimeout = 8000; c.readTimeout = 8000
        c.setRequestProperty("X-Emby-Token", s.optString("accessToken")); c.setRequestProperty("Accept", "application/json")
        return try { if (c.responseCode in 200..299) (if (method == "GET") JSONObject(c.inputStream.bufferedReader().readText()) else JSONObject()) else null } finally { c.disconnect() }
    }

    override suspend fun find(art: String, tmdb: Long): String? = withContext(Dispatchers.IO) {
        if (app.kind() == ServerKind.Plex.raw) return@withContext null
        try {
            val kind = if (art == "tv") "Series" else "Movie"
            val items = call("GET", "/Items?Recursive=true&IncludeItemTypes=$kind&AnyProviderIdEquals=tmdb.$tmdb&Fields=ProviderIds&Limit=20")?.optJSONArray("Items")
                ?: return@withContext null
            (0 until items.length()).map { items.getJSONObject(it) }
                .firstOrNull { it.optJSONObject("ProviderIds")?.optString("Tmdb") == tmdb.toString() }?.optString("Id")?.takeIf { it.isNotEmpty() }
        } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
    }

    override suspend fun refresh() {
        withContext(Dispatchers.IO) {
            if (app.kind() == ServerKind.Plex.raw || runCatching { call("POST", "/Library/Refresh") }.getOrNull() == null)
                throw LibraryFailure.Other("The media server did not take the library scan")
        }
    }
}

val SeerrTileCard.key: String get() = "$art:$tmdb"

fun tmdbImage(path: String?, width: Int): String? =
    path?.takeIf { it.isNotBlank() }?.let { if (it.startsWith("http")) it else "https://image.tmdb.org/t/p/w$width$it" }

/** The colour and glyph of a status, one table for tiles, rows and pages (the core decides the words). */
object SeerrBadgeMark {
    private val amber = Color(0.85f, 0.60f, 0.17f)
    private val blue = Color(0.29f, 0.56f, 0.85f)

    fun color(kind: BadgeKind): Color = when (kind) {
        BadgeKind.WAITS, BadgeKind.SEARCHING, BadgeKind.SOON -> amber
        BadgeKind.FETCHING -> blue
        BadgeKind.DECLINED, BadgeKind.FAILED -> Theme.error
        BadgeKind.BLOCKED -> Theme.fontQuiet
        BadgeKind.REQUESTABLE, BadgeKind.PARTIAL, BadgeKind.AVAILABLE -> Theme.accent
    }

    fun glyph(kind: BadgeKind): Glyph = when (kind) {
        BadgeKind.REQUESTABLE -> Glyph.PlusCircle
        BadgeKind.WAITS, BadgeKind.SOON -> Glyph.Clock
        BadgeKind.SEARCHING -> Glyph.Magnifier
        BadgeKind.FETCHING -> Glyph.LoadCircle
        BadgeKind.PARTIAL -> Glyph.Contrast
        BadgeKind.AVAILABLE -> Glyph.Checkmark
        BadgeKind.DECLINED -> Glyph.Cross
        BadgeKind.FAILED, BadgeKind.BLOCKED -> Glyph.CrossCircle
    }
}

/** A poster tile of the core's list: faded, the capsule says the state (`SeerrTile` on Apple). */
@Composable
fun SeerrCardTile(k: SeerrTileCard, modifier: Modifier = Modifier, perform: () -> Unit) {
    Column(modifier.reveal().tapOn(perform), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(RoundedCornerShape(Theme.cornerTile)).background(Theme.area)) {
            AsyncImage(model = tmdbImage(k.poster, 342), contentDescription = k.title, contentScale = ContentScale.Crop,
                       modifier = Modifier.fillMaxSize().alpha(if (k.onServer) 1f else 0.45f))
            k.badge?.takeIf { !k.onServer }?.let { b -> Capsule(b, Modifier.align(Alignment.BottomStart).padding(6.dp)) }
        }
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(k.title, style = Theme.tile, color = Theme.fontQuiet, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(listOfNotNull(k.year?.toString(), translated(if (k.art == "tv") "Serie" else "Film")).joinToString(" · "),
                 style = Theme.small, color = Theme.fontVeryQuiet, maxLines = 1)
        }
    }
}

/** The status capsule: symbol and the core's short word ("wartet", "62 %", "28. Nov."). */
@Composable
fun Capsule(b: SeerrBadge, modifier: Modifier = Modifier) {
    Row(modifier.clip(CircleShape).background(SeerrBadgeMark.color(b.kind)).padding(horizontal = 7.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        Symbol(SeerrBadgeMark.glyph(b.kind), 10.dp, color = Theme.reason, strength = Strength.Semibold)
        Text(b.word, style = Theme.badge.copy(letterSpacing = 0.sp), color = Theme.reason, maxLines = 1)
    }
}

/** A tile on the server (or partly) opens the library's own page, any other the Seerr page. */
suspend fun openSeerrCard(app: SwiftlyApplication, card: SeerrTileCard, open: (Destination) -> Unit) {
    if (card.art == "movie" || card.art == "tv") {
        val partly = card.badge?.kind == BadgeKind.PARTIAL
        val id = if (card.onServer || partly) app.seerr.library.find(card.art, card.tmdb) else null
        if (id != null) { open(Destination(id, card.title, if (card.art == "tv") "Series" else "Movie")); return }
    }
    open(Destination(card.key, card.title, "Seerrtitel"))
}

/** "Seerr antwortet gerade nicht. Deine Bibliothek läuft normal." with one way out. */
@Composable
fun SeerrOfflineBox(retry: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(bottom = 10.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(translated("Seerr antwortet gerade nicht. Deine Bibliothek läuft normal."), style = Theme.body.copy(lineHeight = 21.sp),
             color = Theme.fontQuiet, modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(Theme.corner)).background(Theme.area).padding(14.dp))
        de.paulherter.swiftly.shared.SecondaryButton(translated("Erneut versuchen")) { retry() }
    }
}

/** The rails of the empty search page (trending, popular, upcoming): the core's order and titles. */
@Composable
fun SeerrDiscoverBlock(app: SwiftlyApplication, rails: SeerrDiscoverRails?, open: (Destination) -> Unit) {
    val run = rememberCoroutineScope()
    // One column: the caller is a single grid item, and several roots in an item are drawn on top of each other.
    Column {
        rails?.rails?.filter { it.tiles.isNotEmpty() }?.forEach { rail ->
            Segment(rail.title, Theme.tileSpacing) {
                tilesWithKey(rail.tiles, { it.key }) { t ->
                    SeerrCardTile(t, Modifier.width(Theme.tileWidth)) { run.launch { openSeerrCard(app, t, open) } }
                }
            }
        }
    }
}

// ---------------------------------------------------------------- request sheet

/** Opens the request sheet of a title page or season chooser: the core's rows, quota line, choices and button. */
fun seerrSheetShow(app: SwiftlyApplication, screen: SeerrTitleScreen, season: Long?, afterwards: () -> Unit) {
    val first = screen.openSheet(season)
    app.sheet.value = SheetRequest(first.title, emptyList(), null, content = { close ->
        SeerrSheetContent(screen, first, close, afterwards)
    }) {}
}

@Composable
private fun SeerrSheetContent(screen: SeerrTitleScreen, first: SeerrSheetInfo, close: () -> Unit, afterwards: () -> Unit) {
    var sheet by remember { mutableStateOf(first) }
    var sending by remember { mutableStateOf(false) }
    val run = rememberCoroutineScope()
    // The quota line and the admin's choices fill in a moment later (`load_sheet`); the sheet is already there.
    LaunchedEffect(Unit) { sheet = withContext(Dispatchers.IO) { try { screen.loadSheet() } catch (e: CancellationException) { throw e } catch (_: Exception) { screen.info().sheet } } }
    Column(Modifier.padding(bottom = 6.dp)) {
        val list = rememberScrollState()
        Column(Modifier.heightIn(max = 320.dp).sheetListFade(list).verticalScroll(list)) {
            sheet.rows.forEach { r -> SheetSeason(r) { sheet = screen.toggle(r.number) } }
            sheet.fourK?.let { f ->
                Row(Modifier.fillMaxWidth().heightIn(min = 50.dp).pressRow { sheet = screen.setFourK(!f.on) }.padding(horizontal = Theme.edgeSpacing),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text(f.label, style = Theme.body, color = Theme.font, modifier = Modifier.weight(1f))
                    Symbol(if (f.on) Glyph.CheckboxFilled else Glyph.Checkbox, 17.dp, color = if (f.on) Theme.accent else Theme.fontVeryQuiet)
                }
            }
            sheet.quality?.let { q -> ChoiceLine(q.label, q.value, q.options.map { it.id to it.name }, q.selected) { id -> sheet = screen.chooseQuality(id.toLong()) } }
            sheet.folder?.let { f -> ChoiceLine(f.label, f.value, f.options.map { it.id to it.name }, f.selected) { id -> sheet = screen.chooseFolder(id) } }
        }
        // **The quota line's space is reserved** (`QuotaLine`): the line fades in inside it, so the button below never moves.
        Text(sheet.quotaLine ?: " ", style = Theme.small, color = if (sheet.quotaWarning) Theme.error else Theme.fontQuiet,
             modifier = Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 10.dp)
                 .graphicsLayer { alpha = if (sheet.quotaLine == null) 0f else 1f })
        sheet.error?.let { Text(it, style = Theme.small, color = Theme.error, modifier = Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 8.dp)) }
        PrimaryButton(if (sending) translated("Wird angefragt…") else sheet.primary.text, released = sheet.primary.enabled && !sending,
                      modifier = Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 12.dp)) {
            sending = true
            run.launch {
                val result = withContext(Dispatchers.IO) { try { screen.confirm() } catch (e: CancellationException) { throw e } catch (_: Exception) { SeerrRequestResult.NotSent } }
                sending = false
                when (result) {
                    is SeerrRequestResult.Requested, is SeerrRequestResult.Exists -> { close(); afterwards() }
                    else -> sheet = screen.info().sheet
                }
            }
        }
    }
}

@Composable
private fun SheetSeason(r: SeerrSeasonRowInfo, toggle: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 50.dp).then(if (r.selectable) Modifier.pressRow(toggle) else Modifier).padding(horizontal = Theme.edgeSpacing),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(r.title, style = Theme.body, color = if (r.selectable) Theme.font else Theme.fontVeryQuiet)
        r.episodes?.let { Text("· $it", style = Theme.small, color = Theme.fontVeryQuiet) }
        Spacer(Modifier.weight(1f))
        if (!r.selectable) Text(r.badge.line, style = Theme.small, color = Theme.fontVeryQuiet)
        else Symbol(if (r.selected) Glyph.CheckboxFilled else Glyph.Checkbox, 17.dp, color = if (r.selected) Theme.accent else Theme.fontVeryQuiet)
    }
}

/**
 * The season chooser of a library series with Seerr (`SeasonPickerSheet` on Apple): one row per season the core knows. A season
 * the server has switches the page (its own name, a tick on the open one); every other one is grey with the core's state and,
 * when it can be asked for, a tap opens the request sheet for exactly that season.
 */
@Composable
fun ColumnScope.SeerrSeasonPicker(rows: List<SeerrSeasonRowInfo>, library: List<Season>, selected: String?,
                                  select: (String) -> Unit, request: (Long) -> Unit) {
    val list = rememberScrollState()
    Column(Modifier.heightIn(max = 360.dp).sheetListFade(list).verticalScroll(list)) {
        rows.forEach { r ->
            val own = if (r.onServer) library.firstOrNull { it.number?.toLong() == r.number } else null
            if (own != null) {
                Row(Modifier.fillMaxWidth().heightIn(min = 50.dp).pressRow { select(own.id) }.padding(horizontal = Theme.edgeSpacing),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text(own.name, style = Theme.body, color = Theme.font, modifier = Modifier.weight(1f))
                    if (own.id == selected) Symbol(Glyph.Checkmark, 17.dp, color = Theme.accent)
                }
            } else {
                Row(Modifier.fillMaxWidth().heightIn(min = 50.dp).then(if (r.selectable) Modifier.pressRow { request(r.number) } else Modifier)
                        .padding(horizontal = Theme.edgeSpacing),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(r.title, style = Theme.body, color = Theme.fontVeryQuiet)
                    r.episodes?.let { Text("· $it", style = Theme.small, color = Theme.fontVeryQuiet) }
                    Spacer(Modifier.weight(1f))
                    Capsule(r.badge)
                }
            }
        }
    }
}

/** A choice row of the admin's sheet ("Qualität", "Ordner"): the value cycles through the options on a tap. */
@Composable
private fun ChoiceLine(label: String, value: String, options: List<Pair<String, String>>, selected: String, choose: (String) -> Unit) {
    // A reserved row (the choices are still being read, no options yet) stands but does nothing.
    Row(Modifier.fillMaxWidth().heightIn(min = 50.dp).then(if (options.isEmpty()) Modifier else Modifier.pressRow {
        val at = options.indexOfFirst { it.first == selected }
        options.getOrNull((at + 1) % options.size.coerceAtLeast(1))?.let { choose(it.first) }
    }).padding(horizontal = Theme.edgeSpacing), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = Theme.body, color = Theme.font, modifier = Modifier.weight(1f))
        Text(value, style = Theme.body, color = Theme.fontQuiet, maxLines = 1)
    }
}

// ---------------------------------------------------------------- home block

internal const val dismissedKey = "seerrArrivalDismissed"
private const val hintKey = "seerrArrivalHint"
fun seerrArrivalOn(app: SwiftlyApplication): Boolean = app.store.rememberValue(hintKey) != "0"
/** The "Meine Anfragen" rail on Home: off until switched on (core key `seerrRequestsRail`). */
fun seerrRequestsOn(app: SwiftlyApplication): Boolean = app.store.rememberValue("seerrRequestsRail") == "1"
/** The two Start switches write the setting and tell the Start page (`StartOrderStore.version`), which reloads the Seerr block with them. */
fun seerrArrivalSet(app: SwiftlyApplication, on: Boolean) { app.store.remember(hintKey, if (on) "1" else "0"); StartOrderStore.version.intValue++ }
fun seerrRequestsSet(app: SwiftlyApplication, on: Boolean) { app.store.remember("seerrRequestsRail", if (on) "1" else "0"); StartOrderStore.version.intValue++ }
internal fun dismissedRead(app: SwiftlyApplication): List<Long> = app.store.rememberValue(dismissedKey).orEmpty().split(',').mapNotNull { it.toLongOrNull() }

/** "Abspielen" on an arrival: a film plays; a series plays its next episode up (its page only when there is none). */
fun arrivalPlay(app: SwiftlyApplication, a: SeerrArrival, open: (Destination) -> Unit) {
    if (a.art != "tv") { playDefault(app, a.libraryId, null); return }
    // A series plays its next episode up, as on Apple: the core's series state names it (`stand`: the episode to resume
    // or the next one, and where to continue). Only a series without any playable episode opens its page.
    app.rk.series(a.libraryId).whenComplete { json, error ->
        val state = if (error == null) runCatching { seriesRead(json).state }.getOrNull() else null
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            if (state != null) playDefault(app, state.id, state.since)
            else open(Destination(a.libraryId, a.title, "Series"))
        }
    }
}

// ---------------------------------------------------------------- my requests

/** The requests as a page of their own (kept for a deep link): the hub's content under the page's header. */
@Composable
fun SeerrRequestsPage(app: SwiftlyApplication, open: (Destination) -> Unit, back: () -> Unit) {
    SettingPage(translated("Meine Anfragen"), back) { SeerrRequestsContent(app, open) }
}

/** The user's requests with the core's state words, filter pills and withdraw: the "Anfragen" section of the hub. */
@Composable
fun ColumnScope.SeerrRequestsContent(app: SwiftlyApplication, open: (Destination) -> Unit) {
    var info by remember { mutableStateOf<SeerrRequestsInfo?>(null) }
    val run = rememberCoroutineScope()
    LaunchedEffect(Unit) {
        // The list of the last visit is there at once (the core's stash); the live read below replaces it.
        val stored = try { withContext(Dispatchers.IO) { app.seerr.lists().restoreRequests() } } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
        if (stored != null && info == null) info = stored
        val live = withContext(Dispatchers.IO) { try { app.seerr.lists().loadRequests() } catch (e: CancellationException) { throw e } catch (_: Exception) { null } }
        info = live ?: info
    }
    val i = info
    when {
        i == null || i.load == ListLoad.LOADING || i.load == ListLoad.IDLE -> Box(Modifier.fillMaxWidth().padding(40.dp), contentAlignment = Alignment.Center) { Spinner(26.dp) }
        i.load == ListLoad.OFFLINE || i.load == ListLoad.FAILED -> Text(i.error ?: translated("Seerr antwortet gerade nicht."), style = Theme.body,
            color = Theme.fontQuiet, modifier = Modifier.padding(horizontal = Theme.edgeSpacing))
        else -> {
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = Theme.edgeSpacing), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                i.pills.forEach { p ->
                    Text(p.title + " " + p.count, style = Theme.small, color = if (p.selected) Theme.reason else Theme.font,
                         modifier = Modifier.clip(CircleShape).background(if (p.selected) Theme.font else Theme.area)
                             .tapOn { info = app.seerr.lists().selectPill(p.pill) }.padding(horizontal = 12.dp, vertical = 7.dp))
                }
            }
            i.quotaSummary?.let { Text(it, style = Theme.small, color = Theme.fontQuiet, modifier = Modifier.padding(horizontal = Theme.edgeSpacing)) }
            if (i.rows.isEmpty()) Text(translated("Noch nichts angefragt."), style = Theme.body, color = Theme.fontQuiet, modifier = Modifier.padding(horizontal = Theme.edgeSpacing))
            i.rows.forEach { r -> RequestRow(r, open = { open(Destination(r.art + ":" + r.tmdb, r.title, "Seerrtitel")) },
                withdraw = { run.launch { info = withContext(Dispatchers.IO) { app.seerr.lists().withdraw(r.id) } } }) }
        }
    }
}

@Composable
private fun RequestRow(r: SeerrRequestRow, open: () -> Unit, withdraw: () -> Unit) {
    Row(Modifier.fillMaxWidth().pressRow(open).padding(horizontal = Theme.edgeSpacing, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        AsyncImage(model = tmdbImage(r.poster, 185), contentDescription = r.title, contentScale = ContentScale.Crop,
                   modifier = Modifier.size(48.dp, 72.dp).clip(RoundedCornerShape(6.dp)).background(Theme.area))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(listOfNotNull(r.title, r.year?.let { "($it)" }).joinToString(" "), style = Theme.listTitle, color = Theme.font, maxLines = 2)
            Text(r.badge.line, style = Theme.small, color = SeerrBadgeMark.color(r.badge.kind))
            r.detail?.let { Text(it, style = Theme.small, color = Theme.fontQuiet) }
            r.workText?.let { Text(it, style = Theme.small, color = Theme.fontQuiet) }
            if (r.canWithdraw) Text(translated("Zurückziehen"), style = Theme.small.copy(fontWeight = FontWeight.SemiBold), color = Theme.accent,
                                    modifier = Modifier.padding(top = 4.dp).tapOn(withdraw))
        }
    }
}
