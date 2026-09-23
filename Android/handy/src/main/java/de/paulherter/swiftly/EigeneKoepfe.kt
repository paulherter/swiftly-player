package de.paulherter.swiftly

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.unit.dp
import de.paulherter.swiftly.gemeinsam.Bewegung
import de.paulherter.swiftly.gemeinsam.Eingabefeld
import de.paulherter.swiftly.gemeinsam.Hauptknopf
import de.paulherter.swiftly.gemeinsam.Staerke
import de.paulherter.swiftly.gemeinsam.Stil
import de.paulherter.swiftly.gemeinsam.Symbol
import de.paulherter.swiftly.gemeinsam.Zeichen
import de.paulherter.swiftly.gemeinsam.uebersetzt
import de.paulherter.swiftly.kern.Kern
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * Eine Zeile in „Erweitert" — Name und Wert eines eigenen Headers. Vorlage: `Kopfzeile` in
 * `Sources/Shared/Anmeldemodell.swift`.
 *
 * **Eine eigene Kennung, nicht der Index.** Wer die zweite von drei Zeilen entfernt, soll nicht
 * zusehen, wie der Wert der dritten in die zweite rutscht, waehrend er noch tippt.
 */
class Kopfzeile(name: String = "", wert: String = "") {
    val id: String = UUID.randomUUID().toString()
    var name by mutableStateOf(name)
    var wert by mutableStateOf(wert)
    /** Den setzt Swiftly selbst — die Zeile sagt es, statt still nichts zu tun. */
    val gesperrt: Boolean get() = Kern.kopfGesperrt(name)
}

/** Die Zeilen als JSON `[{"name","wert"}]` fuer den Kern — der bereinigt sie mit derselben Schleuse wie ueberall. */
fun List<Kopfzeile>.alsJson(): String =
    JSONArray(map { JSONObject().put("name", it.name).put("wert", it.wert) }).toString()

/** Was davon hinausgehen darf — `Eigenkoepfe.bereinigt`, als JSON. */
fun List<Kopfzeile>.bereinigt(): String = Kern.eigenkoepfeBereinigt(alsJson())

fun kopfzeilenAus(json: String): List<Kopfzeile> = runCatching {
    val a = JSONArray(json)
    (0 until a.length()).map { a.getJSONObject(it).let { o -> Kopfzeile(o.optString("name"), o.optString("wert")) } }
}.getOrDefault(emptyList())

/**
 * **Die Header fuer eine Anfrage an diese Adresse** — `Eigenkoepfe.felder(fuer:)` im Paket. Leer fuer
 * jeden fremden Rechner (TMDB, fremde Bilder) und fuer alle, die nichts eingetragen haben.
 */
fun eigenkoepfeFelder(adresse: String): Map<String, String> {
    val o = runCatching { JSONObject(Kern.eigenkoepfeFelder(adresse)) }.getOrNull() ?: return emptyMap()
    return o.keys().asSequence().associateWith { o.getString(it) }
}

/**
 * **Coil (OkHttp) schickt die eigenen Header mit** — Plakate, Kulissen, Kachelblaetter. Vorlage
 * `Bildspeicher` mit `.mitEigenenKoepfen` auf Apple. Ohne Eintrag bleibt die Anfrage, wie sie war.
 * VLC kann keine beliebigen Header; Streams bleiben ausgenommen, wie auf Apple.
 */
object EigenkoepfeAbfang : okhttp3.Interceptor {
    override fun intercept(chain: okhttp3.Interceptor.Chain): okhttp3.Response {
        val anfrage = chain.request()
        val felder = eigenkoepfeFelder(anfrage.url.toString())
        if (felder.isEmpty()) return chain.proceed(anfrage)
        val neu = anfrage.newBuilder()
        felder.forEach { (name, wert) -> neu.header(name, wert) }
        return chain.proceed(neu.build())
    }
}

/**
 * **„Erweitert" — eigene Header fuer einen Dienst vor dem Server.** Vorlage: `Erweitertbereich` in
 * `Sources/Shared/Erweitertbereich.swift`.
 *
 * Cloudflare Access, Authelia, Authentik, Pangolin: wer Jellyfin oder Seerr so absichert, laesst die
 * App nur mit bestimmten Headern durch (Issue #4). Alle anderen brauchen das nie — deshalb
 * **zugeklappt und leer**, und wer es nicht aufmacht, bei dem aendert sich nichts. Die Werte sind
 * Zugaenge: verdeckt eingegeben, im Tresor abgelegt, nie protokolliert.
 */
@Composable
fun Erweitertbereich(zeilen: SnapshotStateList<Kopfzeile>, aufgeklappt: Boolean = false, modifier: Modifier = Modifier) {
    var offen by rememberSaveable { mutableStateOf(false) }
    // Wer schon Header eingetragen hat, soll sie sehen.
    LaunchedEffect(Unit) { if (zeilen.isNotEmpty()) offen = true }
    val drehung by animateFloatAsState(if (offen) 90f else 0f, Bewegung.einblenden(), label = "erweitert")
    Column(modifier.fillMaxWidth()) {
        if (!aufgeklappt) {
            Row(Modifier.heightIn(min = 44.dp).antippen { offen = !offen },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(uebersetzt("Erweitert"), style = Stil.klein, color = Stil.schriftLeise)
                Symbol(Zeichen.WinkelRechts, 11.dp, Modifier.rotate(drehung), farbe = Stil.schriftLeise, staerke = Staerke.Halbfett)
            }
        }
        AnimatedVisibility(offen || aufgeklappt, enter = fadeIn(Bewegung.einblenden()) + expandVertically(Bewegung.einblenden()),
                           exit = fadeOut(Bewegung.einblenden()) + shrinkVertically(Bewegung.einblenden())) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(uebersetzt("Für einen Dienst vor deinem Server, etwa Cloudflare Access, Authelia oder Pangolin. Swiftly schickt die Header nur an diese Adresse."),
                     style = Stil.klein, color = Stil.schriftSehrLeise)
                zeilen.forEach { zeile ->
                    androidx.compose.runtime.key(zeile.id) {
                        Column(Modifier.padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Box(Modifier.weight(1f)) {
                                    Eingabefeld(zeile.name, { zeile.name = it }, Zeichen.Etikett, uebersetzt("Header-Name"))
                                }
                                Box(Modifier.size(44.dp).antippen { zeilen.removeAll { it.id == zeile.id } },
                                    contentAlignment = Alignment.Center) {
                                    Symbol(Zeichen.MinusKreis, 17.dp, farbe = Stil.schriftSehrLeise, beschreibung = uebersetzt("Entfernen"))
                                }
                            }
                            Box(Modifier.padding(end = 52.dp)) {
                                Eingabefeld(zeile.wert, { zeile.wert = it }, Zeichen.Schluessel, uebersetzt("Wert"), geheim = true)
                            }
                            if (zeile.gesperrt) {
                                Text(uebersetzt("Den setzt Swiftly selbst."), style = Stil.klein, color = Stil.warnung)
                            }
                        }
                    }
                }
                // `NebenknopfStil` mit Zeichen und Wort, wie auf dem iPhone.
                Row(Modifier.padding(top = 4.dp).fillMaxWidth().heightIn(min = Stil.knopfHoehe)
                        .background(Stil.flaeche, RoundedCornerShape(Stil.ecke)).antippen { zeilen.add(Kopfzeile()) },
                    horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                    Symbol(Zeichen.Plus, 15.dp, farbe = Stil.schrift)
                    Spacer(Modifier.width(9.dp))
                    Text(uebersetzt("Header hinzufügen"), style = Stil.knopftext, color = Stil.schrift)
                }
            }
        }
    }
}

/** Zeilen fuer „Erweitert", leer zu Beginn — wie `@State private var koepfe: [Kopfzeile] = []`. */
@Composable
fun rememberKopfzeilen(): SnapshotStateList<Kopfzeile> = remember { mutableStateListOf() }

/**
 * **Die eigenen Header des Servers, an dem die App gerade haengt** — Einstellungen → Server. Vorlage
 * `EigeneKoepfeSeite`. Sichern gilt sofort fuer jede weitere Anfrage, auch fuer Bilder und Downloads.
 */
@Composable
fun EigeneKoepfeSeite(app: SwiftlyAnwendung, zurueck: () -> Unit) {
    val server = app.aktiverServer()
    val zeilen = remember { mutableStateListOf<Kopfzeile>().apply { addAll(kopfzeilenAus(app.eigeneKoepfe(server))) } }
    var gesichert by remember { mutableStateOf(Kern.eigenkoepfeBereinigt(app.eigeneKoepfe(server))) }
    Einstellungsseite(uebersetzt("Eigene Header"), zurueck) {
        Column(Modifier.padding(horizontal = Stil.randAbstand).padding(top = 10.dp)) {
            Erweitertbereich(zeilen, aufgeklappt = true)
            if (zeilen.bereinigt() != gesichert && server != null) {
                Hauptknopf(uebersetzt("Sichern"), modifier = Modifier.padding(top = 22.dp)) {
                    app.eigeneKoepfeSichern(zeilen.alsJson(), server)
                    gesichert = Kern.eigenkoepfeBereinigt(app.eigeneKoepfe(server))
                }
            }
        }
    }
}
