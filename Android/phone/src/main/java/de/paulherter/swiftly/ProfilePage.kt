package de.paulherter.swiftly

import de.paulherter.swiftly.shared.Glyph
import de.paulherter.swiftly.shared.Symbol
import de.paulherter.swiftly.shared.Strength
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.paulherter.swiftly.shared.Theme
import de.paulherter.swiftly.shared.translated
import de.paulherter.swiftly.core.Kern
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/** Server and version from `Kern.serverInfo`; `null` until an answer is there. */
@Composable
private fun rememberServerInfo(app: SwiftlyApplication): State<Pair<String, String>?> {
    val inquiry = remember { mutableStateOf<Pair<String, String>?>(null) }
    LaunchedEffect(Unit) {
        try {
            val o = JSONObject(withContext(Dispatchers.IO) { app.kern.serverInfo().await() })
            inquiry.value = o.optString("name") to o.optString("version")
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
    }
    return inquiry
}

/**
 * Mirrors `ProfileView` in Shared.
 *
 * A page of its own instead of a menu: a menu on a 34-point icon felt foreign, and everything in
 * it led elsewhere anyway. Sign out does not ask, as on iOS.
 */
@Composable
fun ProfilePage(app: SwiftlyApplication, open: (Destination) -> Unit, back: () -> Unit) {
    val server by rememberServerInfo(app)
    // If the page opens in the middle of an account switch, it finishes immediately: new account
    // active, profile picture in place (`AccountSwitchTransition.complete`).
    LaunchedEffect(Unit) { AccountSwitchTransition.complete() }
    SettingPage(translated("Profil"), back) {
        AccountCards(app, server, open)
        Spacer(Modifier.height(18.dp))
        CardView {
            ProfileRow(Glyph.TextSearch, translated("Quick Connect"), translated("Code vom Fernseher eingeben"), characterAccent = true) {
                open(Destination("quickconnect", "Quick Connect", "QuickConnect"))
            }
        }
        Spacer(Modifier.height(18.dp))
        CardView {
            ProfileRow(Glyph.Play, translated("Wiedergabe"), translated("Sprache, Untertitel, Tempo")) {
                open(Destination("wiedergabe", translated("Wiedergabe"), "Wiedergabeeinstellungen"))
            }
            SeparatorLine()
            ProfileRow(Glyph.Grid, translated("Darstellung"), translated("Startseite, Reihen, Genres")) {
                open(Destination("darstellung", translated("Darstellung"), "Darstellung"))
            }
            SeparatorLine()
            ProfileRow(Glyph.Gear, translated("Einstellungen")) {
                open(Destination("einstellungen", translated("Einstellungen"), "Einstellungen"))
            }
        }
        Spacer(Modifier.height(18.dp))
        CardView {
            ProfileRow(Glyph.Server, translated("Server hinzufügen"), translated("Ein zweiter Jellyfin, eigene Konten")) {
                open(Destination("serveraufnahme", translated("Server hinzufügen"), "ServerAufnahme"))
            }
            SeparatorLine()
            // Affects only the current account; if others remain, the next one becomes current.
            ProfileRow(Glyph.SignOut, translated("Abmelden")) { app.signOff() }
        }
        Spacer(Modifier.height(18.dp))
        // Rate, Discord, report a bug: at the very bottom (they were in settings and hardly seen). The
        // URLs come from the package. A Play listing entry instead of the in-app prompt: that one
        // appears by itself after the third title, and a row that triggers it often showed nothing in
        // closed testing, because Google throttles the prompt and does not report whether it appeared.
        val context = androidx.compose.ui.platform.LocalContext.current
        CardView {
            ProfileRow(Glyph.Star, translated("Swiftly bewerten"), translated("Im Play Store")) {
                app.addressOpen(context, app.communityAddress("play"))
            }
            SeparatorLine()
            ProfileRow(Glyph.Conversation, translated("Discord beitreten"), translated("Fragen stellen und sagen, was fehlt")) {
                app.addressOpen(context, app.communityAddress("discord"))
            }
            SeparatorLine()
            ProfileRow(Glyph.Beetle, translated("Fehler melden"), translated("Auf GitHub, deine App-Version ist schon eingetragen")) {
                app.addressOpen(context, app.communityAddress("fehler"))
            }
            SeparatorLine()
            // Next to "Report a bug" because it belongs there: whoever reports a bug in Discord attaches this.
            ProfileRow(Glyph.Document, translated("Protokoll teilen"), translated("Die letzte Stunde, ohne Zugangsdaten")) {
                LogFile.distribute(context)
            }
            SeparatorLine()
            ProfileRow(Glyph.Document, translated("Open-Source-Lizenzen")) {
                open(Destination("lizenzen", translated("Open-Source-Lizenzen"), "Lizenzen"))
            }
        }
        // White at 30 percent is 2.67:1 and not allowed for text.
        Text(SwiftlyApplication.VersionRow, style = Theme.small, color = Theme.fontVeryQuiet,
             modifier = Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 26.dp))
    }
}

/** Mirrors `QuickConnectView`: authorize another device's code. */
@Composable
fun QuickConnectPage(app: SwiftlyApplication, back: () -> Unit) {
    var code by remember { mutableStateOf("") }
    var running by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var succeeded by remember { mutableStateOf(false) }
    val run = rememberCoroutineScope()
    SettingPage(translated("Quick Connect"), back) {
        Column(Modifier.padding(horizontal = Theme.edgeSpacing).widthIn(max = Theme.formWidth)) {
            Text(translated("Auf dem anderen Gerät steht ein sechsstelliger Code. Gib ihn hier ein, dann meldet es sich mit deinem Konto an."),
                 style = Theme.body.copy(lineHeight = 21.sp), color = Theme.fontQuiet, modifier = Modifier.padding(top = 10.dp))
            // 28 instead of 34: the digits are the subject of the page, so the title size.
            val digits = Theme.titleLarge.copy(fontWeight = FontWeight.SemiBold, letterSpacing = 0.sp,
                                               fontFeatureSettings = "tnum", textAlign = TextAlign.Center)
            BasicTextField(value = code, onValueChange = { code = it.filter(Char::isDigit).take(6) }, singleLine = true,
                textStyle = digits.copy(color = Theme.font), cursorBrush = SolidColor(Theme.accent),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                modifier = Modifier.fillMaxWidth().padding(top = 26.dp).clip(RoundedCornerShape(Theme.cornerField)).background(Theme.area)
                    .padding(vertical = 16.dp),
                decorationBox = { inputField ->
                    Box(contentAlignment = Alignment.Center) {
                        if (code.isEmpty()) Text("000000", style = digits, color = Theme.fontVeryQuiet, modifier = Modifier.fillMaxWidth())
                        inputField()
                    }
                })
            // Success in the accent, failure in `error`; 13 medium.
            message?.let { Text(it, style = Theme.tile, color = if (succeeded) Theme.accent else Theme.error, modifier = Modifier.padding(top = 12.dp)) }
            // `PrimaryButtonStyle` without icon; after authorizing, the page closes by itself after two seconds.
            de.paulherter.swiftly.shared.PrimaryButton(translated(if (running) "Moment…" else "Freigeben"),
                    released = !running && code.length >= 4, modifier = Modifier.padding(top = 22.dp)) {
                running = true
                message = null
                run.launch {
                    val reason = withContext(Dispatchers.IO) { app.kern.quickConnectShare(code).await() }
                    succeeded = reason.isEmpty()
                    message = if (succeeded) translated("Freigegeben. Das andere Gerät ist gleich angemeldet.") else errorString(reason)
                    running = false
                    if (succeeded) { kotlinx.coroutines.delay(2000); back() }
                }
            }
        }
    }
}

/** Mirrors `PlaybackSettingsView`: quality, language, behavior. */
@Composable
fun PlaybackSettingsPage(app: SwiftlyApplication, back: () -> Unit) {
    val e = app.settings
    val bitrates = remember { selectionRead(Kern.bitrateLevels()) }
    val buffer = remember { JSONArray(Kern.bufferLevels()).let { a -> (0 until a.length()).map { a.getJSONObject(it).let { o -> Choice(o.getString("wert"), o.getString("text")) } } } }
    val seconds = remember { JSONArray(Kern.span()).let { a -> (0 until a.length()).map { a.getInt(it) } } }
    val audioChoice = remember { selectionRead(Kern.languages("")) }
    val subtitleSelection = remember { selectionRead(Kern.languages(translated("Aus"))) }
    fun sheet(title: String, entries: List<Choice>, selected: String, select: (String) -> Unit) {
        app.sheet.value = SheetRequest(title, entries, selected, select = select)
    }
    fun secondsSelection(): List<Choice> = seconds.map { Choice(it.toString(), translated("%lld s", it)) }

    SettingPage(translated("Wiedergabe"), back) {
        // If the server does not transcode, there is nothing to choose: Direct Play is fixed on and
        // the bitrate is locked.
        val free = e.convertAllowed
        val directPlay = e.alwaysDirectPlay || !free

        SettingGroup(translated("Qualität")) {
            ChoiceRow(Glyph.Play, translated("Immer Direct Play"), translated("Der Server wandelt nie um, es läuft immer die Originaldatei"),
                      directPlay, locked = !free) { e.alwaysDirectPlay = it; app.qualityReport() }
            SeparatorLine()
            // Dimmed while Direct Play is forced, since it would not apply.
            ValueRow(Glyph.Bar, translated("Höchste Bitrate"),
                      value = bitrates.firstOrNull { it.value == e.bitratesLimit.toString() }?.text, dimmedDown = directPlay) {
                sheet(translated("Höchste Bitrate"), bitrates, e.bitratesLimit.toString()) { e.bitratesLimit = it.toInt(); app.qualityReport() }
            }
        }

        SettingGroup(translated("Sprache")) {
            ValueRow(Glyph.Speaker, translated("Ton"), value = audioChoice.firstOrNull { it.value == e.audioLanguage }?.text) {
                sheet(translated("Ton"), audioChoice, e.audioLanguage) { e.audioLanguage = it }
            }
            SeparatorLine()
            ValueRow(Glyph.Subtitle, translated("Untertitel"), value = subtitleSelection.firstOrNull { it.value == e.subtitleLanguage }?.text) {
                sheet(translated("Untertitel"), subtitleSelection, e.subtitleLanguage) { e.subtitleLanguage = it }
            }
            SeparatorLine()
            ChoiceRow(Glyph.TextBlock, translated("Untertitel automatisch"), translated("Nur wenn der Ton nicht in der gewählten Sprache läuft"),
                      e.subtitleAutomatic) { e.subtitleAutomatic = it }
        }

        SettingGroup(translated("Verhalten")) {
            ChoiceRow(Glyph.Skip, translated("Nächste Folge automatisch"), an = e.nextAutomatic) { e.nextAutomatic = it }
            SeparatorLine()
            ChoiceRow(Glyph.WaveSearch, translated("Technische Daten im Player"), an = e.techBadge) { e.techBadge = it }
            SeparatorLine()
            ValueRow(Glyph.Rewind, translated("Zurückspulen"), value = translated("%lld s", e.backSeconds)) {
                sheet(translated("Zurückspulen"), secondsSelection(), e.backSeconds.toString()) { e.backSeconds = it.toInt() }
            }
            SeparatorLine()
            ValueRow(Glyph.FastForward, translated("Vorspulen"), value = translated("%lld s", e.forwardSeconds)) {
                sheet(translated("Vorspulen"), secondsSelection(), e.forwardSeconds.toString()) { e.forwardSeconds = it.toInt() }
            }
            SeparatorLine()
            // Under behavior, not quality: the buffer changes endurance, not the picture.
            ValueRow(Glyph.WlanDisruption, translated("Puffer"), value = buffer.firstOrNull { it.value == e.bufferLevel }?.text) {
                sheet(translated("Puffer"), buffer, e.bufferLevel) { e.bufferLevel = it }
            }
            SeparatorLine()
            ChoiceRow(Glyph.Speaker, translated("Mehrkanal-Ton (5.1)"),
                      translated("Schickt 5.1 und 7.1 so raus, wie sie in der Datei stehen. Kommt kein Ton, schalt es wieder aus."),
                      e.multiChannelAudio) { e.multiChannelAudio = it }
        }
    }
}

/**
 * Mirrors `PresentationView`: General, Home (reorderable, individually switchable), Genres. One
 * genre list, no second hidden one (before, "Chips" silently swapped the data).
 */
@Composable
fun PresentationPage(app: SwiftlyApplication, open: (Destination) -> Unit, back: () -> Unit) {
    val e = app.settings
    SettingPage(translated("Darstellung"), back) {
        SettingGroup(translated("Allgemein")) {
            ChoiceRow(Glyph.Rectangles, translated("Querformat im Player sperren"), an = e.landscapeFixed) { e.landscapeFixed = it }
            SeparatorLine()
            ChoiceRow(Glyph.BarFilled, translated("Fortschritt auf Kacheln"), an = e.progress) { e.progress = it }
            SeparatorLine()
            ChoiceRow(Glyph.TextBlock, translated("Titel als Logo"), translated("Auf Film- und Serienseiten, wenn dein Server eins hat"),
                      e.titleAsLogo) { e.titleAsLogo = it }
        }

        SettingGroup(translated("Startseite")) {
            val rails = remember(e.startRails, e.newAccessDisconnected) {
                selectionRead(Kern.startRails(e.startRails.toTypedArray(), e.newAccessDisconnected))
            }
            SortBar(rails, { it.value }, move = { r, step ->
                e.startRails = JSONArray(Kern.startRailShifted(r.value, step.toLong(), e.startRails.toTypedArray(), e.newAccessDisconnected))
                    .let { a -> (0 until a.length()).map { a.getString(it) } }
            }) { r ->
                // Each row with its own icon (`StartRail.symbol`).
                val symbolText = when (r.value) {
                    "weiterschauen" -> Glyph.PlayCircle
                    "naechsteFolge" -> Glyph.SkipOutline
                    "neueFilme" -> Glyph.Film
                    "neueSerien" -> Glyph.Tv
                    else -> Glyph.Funkeln
                }
                ChoiceRow(symbolText, translated(r.text), an = r.value !in e.startOut) { an ->
                    e.startOut = if (an) e.startOut - r.value else e.startOut + r.value
                }
            }
            SeparatorLine()
            ChoiceRow(Glyph.Shared, translated("Neuzugänge getrennt"), translated("Neue Filme und neue Serien als eigene Reihen"),
                      e.newAccessDisconnected) { e.newAccessDisconnected = it }
        }
        Footer(translated("Zum Umsortieren an den Griffen rechts ziehen."))

        // Mirrors `libraryRails` in `PresentationView`: custom rows from the server's libraries and
        // collections, after the fixed rows, sortable among themselves.
        SettingGroup(translated("Bibliotheken und Sammlungen")) {
            SortBar(e.startLibraries, { it.id }, move = { b, step ->
                val list = e.startLibraries.toMutableList()
                val from = list.indexOfFirst { it.id == b.id }
                val to = (from + step).coerceIn(0, list.lastIndex)
                if (from >= 0 && from != to) { list.removeAt(from); list.add(to, b); e.startLibraries = list }
            }) { b ->
                Row(Modifier.fillMaxWidth().padding(start = Theme.edgeSpacing).heightIn(min = 52.dp), verticalAlignment = Alignment.CenterVertically) {
                    // The name comes from the server, not translated.
                    Text(b.name, style = Theme.body, color = Theme.font, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Box(Modifier.size(44.dp).tapOn { e.startLibraries = e.startLibraries.filter { it.id != b.id } }, contentAlignment = Alignment.Center) {
                        Symbol(Glyph.CrossCircle, 17.dp, color = Theme.fontVeryQuiet, description = translated("Löschen"))
                    }
                }
            }
            if (e.startLibraries.isNotEmpty()) SeparatorLine()
            Row(Modifier.fillMaxWidth().pressRow { open(Destination("bibliothekswahl", translated("Bibliothek hinzufügen"), "Bibliothekswahl")) }
                    .padding(horizontal = Theme.edgeSpacing, vertical = 15.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Box(Modifier.width(Theme.characterColumn), contentAlignment = Alignment.Center) { Symbol(Glyph.Plus, 15.dp, color = Theme.accent, strength = Strength.Semibold) }
                Text(translated("Bibliothek hinzufügen"), style = Theme.listTitle, color = Theme.accent)
            }
        }

        SettingGroup(translated("Genres")) {
            // One list, two forms.
            PresentationShape(Glyph.Rows, translated("Als eigene Reihen"), !e.genreChips) { e.genreChips = false }
            SeparatorLine()
            PresentationShape(Glyph.Pill, translated("Als Chips über den Reihen"), e.genreChips) { e.genreChips = true }
            if (e.startGenres.isNotEmpty()) SeparatorLine()
            SortBar(e.startGenres, { it }, move = { g, step ->
                val list = e.startGenres.toMutableList()
                val from = list.indexOf(g)
                val to = (from + step).coerceIn(0, list.lastIndex)
                if (from >= 0 && from != to) { list.removeAt(from); list.add(to, g); e.startGenres = list }
            }) { g ->
                Row(Modifier.fillMaxWidth().padding(start = Theme.edgeSpacing).heightIn(min = 52.dp), verticalAlignment = Alignment.CenterVertically) {
                    // The genre name in 15 regular: it is an entry, not a row with a title.
                    Text(g, style = Theme.body, color = Theme.font, modifier = Modifier.weight(1f))
                    Box(Modifier.size(44.dp).tapOn { e.startGenres = e.startGenres - g }, contentAlignment = Alignment.Center) {
                        Symbol(Glyph.CrossCircle, 17.dp, color = Theme.fontVeryQuiet, description = translated("Löschen"))
                    }
                }
            }
            if (e.startGenres.isNotEmpty()) SeparatorLine()
            Row(Modifier.fillMaxWidth().pressRow { open(Destination("genrewahl", translated("Genre hinzufügen"), "Genrewahl")) }
                    .padding(horizontal = Theme.edgeSpacing, vertical = 15.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Box(Modifier.width(Theme.characterColumn), contentAlignment = Alignment.Center) { Symbol(Glyph.Plus, 15.dp, color = Theme.accent, strength = Strength.Semibold) }
                Text(translated("Genre hinzufügen"), style = Theme.listTitle, color = Theme.accent)
            }
        }
    }
}

@Composable
private fun PresentationShape(symbol: Glyph, title: String, selected: Boolean, select: () -> Unit) {
    // Selected means white and surface, not color: the checkmark in white, the row on `erhoeht`.
    // The accent carries state, not rank among siblings.
    RowsLayout(symbol, title, null, Theme.font,
                 Modifier.background(if (selected) Theme.raised else Color.Transparent).tapOn(select)) {
        if (selected) Symbol(Glyph.Checkmark, 13.dp, color = Theme.font, strength = Strength.Semibold)
    }
}

/** Mirrors `SettingsView` without Offline and Integration: server and connection. */
@Composable
fun SettingsPage(app: SwiftlyApplication, open: (Destination) -> Unit, back: () -> Unit) {
    val server by rememberServerInfo(app)
    var checks by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<String?>(null) }
    val run = rememberCoroutineScope()
    SettingPage(translated("Einstellungen"), back) {
        // No downloads on TV: there is no storage to fill (tvOS).
        if (!app.isTv) OfflineGroup(app)
        // Integration before server: a second service, not a second server.
        SettingGroup(translated("Integration")) {
            ValueRow(Glyph.SparkleSearch, "Seerr", translated("Anfragen, was noch nicht da ist"),
                      value = if (app.seerrConnected.value) translated("Verbunden") else null) {
                open(Destination("seerr", "Seerr", "Seerr"))
            }
        }
        SettingGroup(translated("Server")) {
            ValueRow(Glyph.Server, server?.first?.takeIf { it.isNotEmpty() } ?: app.serverName.value.orEmpty().ifEmpty { "Jellyfin" },
                      value = server?.second ?: "?")
            SeparatorLine()
            ValueRow(Glyph.Wlan, translated("Verbindung prüfen"), under = result,
                      value = if (checks) translated("Moment…") else null,
                      perform = if (checks) null else { {
                          checks = true
                          run.launch {
                              result = try {
                                  val o = JSONObject(withContext(Dispatchers.IO) { app.kern.serverInfo().await() })
                                  translated("Erreichbar — Jellyfin %@", o.optString("version"))
                              } catch (e: CancellationException) { throw e } catch (e: Exception) { errorString(app, e) }
                              checks = false
                          }
                      } })
            SeparatorLine()
            // Custom headers (issue #4). Only for servers behind a service like Cloudflare Access; everyone
            // else never enters here.
            val count = remember(app.accountSwitch.intValue) { org.json.JSONArray(app.ownHeaders(app.activeServer())).length() }
            ValueRow(Glyph.Keys, translated("Eigene Header"), translated("Für einen Dienst vor dem Server"),
                      value = if (count == 0) null else count.toString()) {
                open(Destination("eigenkoepfe", translated("Eigene Header"), "EigeneKoepfe"))
            }
        }
        Text("${SwiftlyApplication.VersionRow} · libVLC 3.6.3", style = Theme.small, color = Theme.fontVeryQuiet,
             modifier = Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 26.dp))
    }
}

/** Mirrors `GenreSelectionView`: the server's genres not yet on the home screen. A tap adds one. */
@Composable
fun GenreSelectionPage(app: SwiftlyApplication, back: () -> Unit) {
    val e = app.settings
    var all by remember { mutableStateOf<List<String>?>(null) }
    LaunchedEffect(Unit) {
        all = try {
            JSONArray(withContext(Dispatchers.IO) { app.kern.genres().await() }).let { a -> (0 until a.length()).map { a.getString(it) } }
        } catch (e: CancellationException) { throw e } catch (_: Exception) { emptyList() }
    }
    SettingPage(translated("Genre hinzufügen"), back) {
        val list = all ?: return@SettingPage
        val free = list.filter { it !in e.startGenres }
        if (free.isEmpty()) {
            // Two cases, two sentences: the server has none, or all are already there.
            Text(translated(if (list.isEmpty()) "Auf deinem Server sind keine Genres hinterlegt." else "Alle Genres stehen schon auf der Startseite."),
                 style = Theme.body, color = Theme.fontQuiet, modifier = Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 8.dp))
        } else {
            SettingGroup(translated("Auf deinem Server")) {
                free.forEachIndexed { i, g ->
                    if (i > 0) SeparatorLine()
                    // The whole row is the button, without a chevron: it leads nowhere, it adds.
                    Box(Modifier.tapOn { e.startGenres = e.startGenres + g; back() }) { ValueRow(Glyph.Tag, g) }
                }
            }
        }
    }
}

/** Mirrors `LibrarySelectionView`: the server's libraries and collections not yet on the home screen. A tap adds one. */
@Composable
fun LibrarySelectionPage(app: SwiftlyApplication, back: () -> Unit) {
    val e = app.settings
    var free by remember { mutableStateOf<List<StartLibraryItem>?>(null) }
    LaunchedEffect(Unit) { free = startSelectionLoad(app) }
    SettingPage(translated("Bibliothek hinzufügen"), back) {
        val list = free ?: return@SettingPage
        if (list.isEmpty()) {
            // Two cases, two sentences: the server has none, or all are already there.
            Text(translated(if (e.startLibraries.isEmpty()) "Auf deinem Server gibt es keine Bibliotheken." else "Alle Bibliotheken und Sammlungen stehen schon auf der Startseite."),
                 style = Theme.body, color = Theme.fontQuiet, modifier = Modifier.padding(horizontal = Theme.edgeSpacing).padding(top = 8.dp))
        } else {
            SettingGroup(translated("Auf deinem Server")) {
                list.forEachIndexed { i, b ->
                    if (i > 0) SeparatorLine()
                    Box(Modifier.tapOn { e.startLibraries = e.startLibraries + b; back() }) {
                        ValueRow(if (b.collection) Glyph.Store else Glyph.Grid, b.name)
                    }
                }
            }
        }
    }
}

/** What is available as a custom home row (`Kern.startSelection`); empty on error. */
suspend fun startSelectionLoad(app: SwiftlyApplication): List<StartLibraryItem> = try {
    val raw = app.settings.startLibrariesJson()
    JSONArray(withContext(Dispatchers.IO) { app.kern.startSelection(raw).await() }).let { a ->
        (0 until a.length()).map { a.getJSONObject(it).let { o -> StartLibraryItem(o.getString("id"), o.optString("name"), o.optBoolean("sammlung", false)) } }
    }
} catch (e: CancellationException) { throw e } catch (_: Exception) { emptyList() }
