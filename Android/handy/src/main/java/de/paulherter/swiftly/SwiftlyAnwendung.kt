package de.paulherter.swiftly

import android.app.Application
import android.content.Context
import android.os.Build
import de.paulherter.swiftly.gemeinsam.Texte
import de.paulherter.swiftly.kern.Kern
import kotlinx.coroutines.launch
import coil3.request.crossfade
import kotlinx.coroutines.future.await
import org.swift.swiftkit.core.SwiftArena
import java.io.File
import java.util.Locale
import java.util.UUID

/**
 * **Was die App einmal beim Start braucht:** Texte, die Uebersetzungen des Pakets,
 * und den Kern. Der Kern lebt so lange wie die App — wie `AppModel` auf Apple.
 */
class SwiftlyAnwendung : Application(), coil3.SingletonImageLoader.Factory {
    lateinit var kern: Kern
        private set
    lateinit var ablage: Ablage
        private set
    lateinit var einstellungen: Einstellungen
        private set

    /** Zaehlt Abmeldungen — die Aktivitaet kehrt dann zur Serverwahl zurueck. */
    val abgemeldet = androidx.compose.runtime.mutableIntStateOf(0)
    /** Zaehlt Kontowechsel — `AppModel.kontowechsel`: die Hauptansicht baut sich dann neu. */
    val kontowechsel = androidx.compose.runtime.mutableIntStateOf(0)
    private val lauf = kotlinx.coroutines.MainScope()

    /**
     * **Die zuletzt geladenen Reihen der Startseite.** Compose baut eine Seite beim
     * Bereichswechsel ab; ohne diesen Stand stand die Startseite beim Zurueckkommen
     * eine Sekunde leer. Auf iOS haelt `HauptView` das `Startseitenmodell` genauso.
     */
    var startReihen: List<Reihe>? = null
    /** Wann die Startseite zuletzt geladen wurde — fuer `Auffrischung` beim Zurueckkommen. */
    var startGeladenUm = 0L

    /** Je Gattung ein Stand — wie die Modelle in `HauptView`, die den Bereichswechsel ueberleben. */
    val bibliotheken = mutableMapOf<String, Bibliotheksstand>()

    /** Der letzte Stand je Titel — zurueck aus einer tieferen Seite baut sonst neu auf. */
    val titelSpeicher = mutableMapOf<String, Titel>()

    /**
     * **Gegenstueck zu `Serienspeicher`** — nur, damit der Weg zurueck nicht leer ist, nicht als
     * Wahrheit ueber den Sehstand: die Seite laedt immer darueber. Schluessel ist das Ziel
     * (Serie oder Folge), die Folgen haengen an der Staffel.
     */
    val serienSpeicher = mutableMapOf<String, Serie>()
    val folgenSpeicher = mutableMapOf<String, List<Folge>>()
    val personenSpeicher = mutableMapOf<String, Personenstand>()

    /** Das offene Auswahlblatt. Es liegt ueber der Leiste, deshalb haelt es die App, nicht die Seite. */
    val blatt = androidx.compose.runtime.mutableStateOf<Blattwunsch?>(null)

    /** Was gerade abgespielt wird — der Player liegt ueber allen Seiten, unter dem Blatt. */
    val spiel = androidx.compose.runtime.mutableStateOf<Abspielwunsch?>(null)

    /**
     * Zaehlt beendete Wiedergaben — **erst, wenn die Endmeldung durch ist**. Vorlage
     * `AppModel.wiedergabeBeendet`: wer schon beim Schliessen neu laedt, fragt, bevor der Server die
     * Stelle kennt, und bekommt den Stand des letzten Takts. Seiten mit Fortschritt haengen hier an.
     */
    val wiedergabeBeendet = androidx.compose.runtime.mutableIntStateOf(0)

    /**
     * Welcher Wunsch schon an `PlayerAktivitaet` uebergeben wurde. **Kein Compose-Zustand und nicht
     * an eine Aktivitaet gebunden:** wird die Hauptaktivitaet neu gebaut (Drehung), waehrend der
     * Player laeuft, lief ihr `LaunchedEffect(spiel)` erneut und startete dieselbe Folge ein zweites
     * Mal — sichtbar erst beim Schliessen, weil der alte Player erst danach `spiel` leert.
     */
    @Volatile var spielUebergeben: Abspielwunsch? = null

    /** Nach einem fertig geschauten Titel steht die Bewertungsfrage an — die Hauptaktivitaet fragt und setzt zurueck. */
    val bewertungFaellig = androidx.compose.runtime.mutableStateOf(false)

    /**
     * Vorlage: `AppModel.fertigGeschaut`. **Die Regel steht im Paket** (`Bewertungsfrage`): ab 90 %
     * eines Titels ueber einer Minute zaehlt er, ab dem dritten wird gefragt — einmal je Fassung.
     * Dieselben Schluessel wie in `UserDefaults` auf iOS.
     */
    fun fertigGeschaut(position: Double, dauer: Double) {
        if (!Kern.bewertungZaehlt(position, dauer)) return
        val fertig = (ablage.merkwert("bewertungFertig")?.toIntOrNull() ?: 0) + 1
        ablage.merken("bewertungFertig", fertig.toString())
        if (!Kern.bewertungFaellig(fertig.toLong(), ablage.merkwert("bewertungFassung").orEmpty(), BuildConfigFassung)) return
        ablage.merken("bewertungFassung", BuildConfigFassung)
        bewertungFaellig.value = true
    }

    /** Laeuft der Player gerade im kleinen Fenster? Dann zeigt die App darunter, wo der Film ist. */
    val kleinesFenster = androidx.compose.runtime.mutableStateOf(false)

    /** „Hier weiterschauen" — was auf einem anderen Geraet desselben Kontos laeuft. */
    val angebote = androidx.compose.runtime.mutableStateOf<List<Angebot>>(emptyList())

    /**
     * Fernseher: die Adresse aus einem Tipp auf einen Watch-Next-Eintrag (`TvAktivitaet`,
     * `TvWeiterschauenRegal`) — `TvHaupt` liest sie, oeffnet den Titel und setzt sie zurueck auf
     * `null`. Genau die "swiftly://titel/<id>"-Adresse, die auch tvOS' Top Shelf verwendet
     * (`RegalAnbieter.swift`), nur ohne `onOpenURL`: Android liefert sie ueber den Intent.
     */
    val tiefenlink = androidx.compose.runtime.mutableStateOf<android.net.Uri?>(null)

    /** Das Zeichen der Mediensitzung des Players — der Wiedergabedienst haengt seine Benachrichtigung daran. */
    var medienToken: android.media.session.MediaSession.Token? = null

    /** Begriff, Treffer und Suchzustand — ueberleben den Bereichswechsel wie auf iOS. */
    val suche = Suchstand()

    /** Seerr verbunden? Wer es nicht ist, sieht nirgends eine Spur davon. */
    val seerrVerbunden = androidx.compose.runtime.mutableStateOf(false)
    /** Treffer, deren Detailseite geoeffnet wird — die Seite braucht Stand, Jahr und Bild vorab. */
    val seerrTreffer = mutableMapOf<String, Seerrkachel>()

    /** Je Jellyfin-Server ein Zugang — so ueberlebt Seerr den Wechsel zu einem anderen Server. */
    private fun seerrSchluessel(): String = "seerr|" + ablage.konten?.let { Kern.bundAktives(it) }?.let {
        runCatching { org.json.JSONObject(it).optString("serverURL") }.getOrNull()
    }.orEmpty().lowercase().trimEnd('/')

    fun seerrLaden() {
        val zugang = ablage.tresorLesen(seerrSchluessel())
        if (zugang != null) kern.seerrSetzen(zugang) else kern.seerrTrennen()
        seerrVerbunden.value = zugang != null
    }
    fun seerrMerken(zugang: String) { ablage.tresorSchreiben(seerrSchluessel(), zugang); seerrVerbunden.value = true }
    fun seerrTrennen() { ablage.tresorSchreiben(seerrSchluessel(), null); kern.seerrTrennen(); seerrVerbunden.value = false }
    fun seerrAdresse(): String? = ablage.tresorLesen(seerrSchluessel())?.let {
        runCatching { org.json.JSONObject(it).optString("adresse") }.getOrNull()
    }

    /** Laeuft die App auf einem Fernseher? Dann ohne Downloads, wie tvOS. */
    val istFernseher: Boolean by lazy { packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_LEANBACK) }

    /** Downloads — die Liste lebt so lange wie die App, wie `Downloadverwaltung` auf iOS. */
    val downloads by lazy { Downloadverwaltung(this) }

    /** Die `userID` des geltenden Kontos — H11: Downloads und Nachmeldungen haengen daran. */
    fun kontoKennung(): String = ablage.konten?.let { Kern.bundAktives(it) }?.let {
        runCatching { org.json.JSONObject(it).optString("userID") }.getOrNull()
    }.orEmpty()

    /** Ende der Wiedergabe melden; scheitert es, wird die Stelle abgelegt und spaeter nachgemeldet (H8). */
    fun wiedergabeBeenden(position: Double) {
        lauf.launch {
            val meldung = runCatching {
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { kern.wiedergabeBeenden(position).await() }
            }.getOrDefault("")
            if (meldung.isNotEmpty()) nachmeldungAblegen(meldung)
            protokollSchreiben()
            wiedergabeBeendet.intValue += 1
        }
    }

    /** Eine Nachmeldung aus dem Kern ablegen — beim Schliessen und beim Folgenwechsel. */
    fun nachmeldungAblegen(meldung: String) {
        ablage.merken(NACHMELDUNGEN, Kern.nachmeldungAufnehmen(ablage.merkwert(NACHMELDUNGEN) ?: "[]", meldung))
    }

    /** Die Meldezeilen des Kerns (Start, Stopped, Wechsel) ins logcat unter „Swiftly". */
    fun protokollSchreiben() {
        kern.protokollAbholen().takeIf { it.isNotEmpty() }?.lines()?.forEach { android.util.Log.i("Swiftly", "[Melden] $it") }
    }

    /**
     * **Nach einer erfolgreichen Verbindung** — der einzige Punkt, an dem der Server nachweislich da ist:
     * Liegengebliebenes abschicken, dann Gesehen und „noch auf dem Server" der Downloads nachziehen.
     */
    suspend fun nachDemVerbinden() {
        if (servername.value == null) return
        val roh = ablage.merkwert(NACHMELDUNGEN) ?: "[]"
        if (roh != "[]") runCatching { kern.nachmeldungenAbschicken(roh).await() }.getOrNull()?.let { ablage.merken(NACHMELDUNGEN, it) }
        downloads.nachziehen()
    }

    /** Posten beim Kern holen, dann das Ladeblatt — was schon da ist, faellt vorher heraus. */
    fun downloadsAnlegen(ids: List<String>, titel: String) {
        lauf.launch {
            val roh = runCatching { kern.downloadPosten(ids.toTypedArray()).await() }.getOrNull() ?: return@launch
            val a = org.json.JSONArray(roh)
            val neue = mutableListOf<Downloadposten>()
            val bilder = mutableMapOf<String, String>()
            for (i in 0 until a.length()) {
                val o = a.getJSONObject(i)
                val p = Downloadposten.lesen(o.getJSONObject("posten"))
                if (downloads.posten(p.id) != null) continue
                neue += p
                o.feldText("bild")?.let { bilder[p.id] = it }
                p.serienId?.let { sid -> o.feldText("serienbild")?.let { bilder[sid] = it } }
            }
            if (neue.isNotEmpty()) ladeblattZeigen(this@SwiftlyAnwendung, neue, bilder, titel)
        }
    }

    /** Gattung, Sortierung und die geladenen Titel der Merkliste. */
    val merkliste by lazy { Merklistenstand(ablage) }

    /**
     * **Der Servername, einmal fuer alle Seiten** — wie `AppModel.serverName`. `null` heisst
     * „noch nicht gefragt", leer heisst „der Server nennt keinen".
     *
     * Er stand in jeder Bibliothek einzeln und kam dort erst nach den Platzhaltern an; der Kopf
     * wuchs dann um eine Zeile und das ganze Raster rutschte herunter.
     */
    val servername = androidx.compose.runtime.mutableStateOf<String?>(null)

    suspend fun servernameLaden() {
        if (servername.value != null) return
        try {
            servername.value = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                kern.servername().await()
            }
        } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) {}
    }

    /**
     * Bilder blenden beim ersten Laden ein — `Bild` auf iOS, `Stil.einblenden`. Was schon im
     * Speicher liegt, steht sofort da: Coil blendet Treffer aus dem Speicher nicht.
     */
    override fun newImageLoader(context: coil3.PlatformContext): coil3.ImageLoader =
        coil3.ImageLoader.Builder(context).crossfade(280).build()

    override fun onCreate() {
        super.onCreate()
        ablage = Ablage(this)
        einstellungen = Einstellungen(ablage)
        Texte.laden(this)
        val sprache = if (Locale.getDefault().language == "de") "de" else "en"
        // Vor dem ersten Text aus dem Paket — sonst stehen dort die Schluessel.
        Kern.paketspracheSetzen(paketspracheEntpacken().absolutePath, sprache)
        // „Android" im Programmnamen: daran erkennen andere Geraete ein Telefon (oder den Fernseher).
        kern = Kern.init(ablage.geraeteID(), Build.MODEL ?: "Android", BuildConfigFassung,
                         if (istFernseher) "Swiftly Player Android TV" else "Swiftly Player Android", SwiftArena.ofAuto())
        qualitaetMelden()
    }

    /** Direct Play und Bitrate an die Fassade — beim Start und bei jeder Aenderung. */
    fun qualitaetMelden() = kern.wiedergabeWahlen(einstellungen.immerDirectPlay, einstellungen.bitratenGrenze.toLong())


    /**
     * Stellt das geltende Konto wieder her. **Umzug:** eine einzelne Sitzung von frueher wird beim
     * ersten Start zum Buendel — niemand muss sich neu anmelden.
     */
    fun sitzungWiederherstellen(): Boolean {
        if (ablage.konten == null) {
            ablage.sitzung?.let { alt -> Kern.bundAusSitzung(alt).takeIf { it.isNotEmpty() }?.let { ablage.konten = it } }
        }
        val bund = ablage.konten ?: return false
        val aktiv = Kern.bundAktives(bund).takeIf { it.isNotEmpty() } ?: return false
        return try { kern.sitzungSetzen(aktiv); true } catch (e: Exception) { false }
    }

    /**
     * Ein Satz fuer die Serverwahl, nachdem eine widerrufene Anmeldung abgemeldet wurde. Die Seite
     * zeigt ihn als Fehler und leert ihn.
     */
    val anmeldehinweis = androidx.compose.runtime.mutableStateOf<String?>(null)
    private var sitzungGeprueft = false

    /**
     * Vorlage: `AppModel` nach dem Wiederherstellen (T2-M7). **Gilt das Merkmal nicht mehr** (Gerät im
     * Dashboard entfernt, Passwort geaendert), wird abgemeldet: bleibt ein Konto, gilt das naechste,
     * sonst geht es zur Serverwahl. Vorher oeffnete die App auf eine leere Startseite mit einem
     * Fehler, und zurueck kam man nur ueber Profil → Abmelden. Laeuft in `lauf`, nicht in der
     * Hauptansicht: die baut sich beim Abmelden ab und wuerde die Pruefung mitten drin abbrechen.
     */
    fun sitzungPruefen() {
        // Einmal je Start, wie auf Apple — nicht bei jeder Drehung, die die Hauptansicht neu baut.
        if (sitzungGeprueft) return
        sitzungGeprueft = true
        kontovorgabenHolen()
        lauf.launch {
            val gilt = runCatching {
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { kern.sitzungGilt().await() }
            }.getOrDefault(true)
            if (gilt) return@launch
            val name = benutzername()
            val rest = ablage.konten?.let { Kern.bundEntfernt(it, Kern.bundAktiveKennung(it)) }.orEmpty()
            val weiter = rest.takeIf { it.isNotEmpty() }?.let { Kern.bundAktives(it) }
                ?.let { runCatching { org.json.JSONObject(it).optString("userName") }.getOrNull() }
            val satz = if (weiter.isNullOrEmpty()) de.paulherter.swiftly.gemeinsam.uebersetzt("Die Anmeldung gilt nicht mehr. Bitte neu anmelden.")
                       else de.paulherter.swiftly.gemeinsam.uebersetzt("Die Anmeldung von %@ gilt nicht mehr. Jetzt angemeldet als %@.", name, weiter)
            android.util.Log.i("Swiftly", "Anmeldung widerrufen, abgemeldet (weiteres Konto: ${!weiter.isNullOrEmpty()})")
            if (weiter.isNullOrEmpty()) anmeldehinweis.value = satz
            else android.widget.Toast.makeText(this@SwiftlyAnwendung, satz, android.widget.Toast.LENGTH_LONG).show()
            abmeldenJetzt()
        }
    }

    /**
     * `EnableNextEpisodeAutoPlay` des geltenden Kontos (T3 #15) — wer „Nächste Folge automatisch" nie
     * umgelegt hat, folgt dem Server, wie `AppModel` auf iOS. Nebenher, ohne Fehlermeldung.
     */
    fun kontovorgabenHolen() {
        einstellungen.naechsteAutomatischKonto = ""
        lauf.launch {
            einstellungen.naechsteAutomatischKonto = runCatching {
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { kern.kontoNaechsteAutomatisch().await() }
            }.getOrDefault("")
        }
    }

    /** Der Name des geltenden Kontos — fuer das Profilzeichen. */
    fun benutzername(): String = ablage.konten?.let { Kern.bundAktives(it) }?.let {
        runCatching { org.json.JSONObject(it).optString("userName") }.getOrNull()
    }.orEmpty().ifEmpty { "?" }

    /** Nimmt eine frische Sitzung auf; gab es schon Konten, ist das ein Wechsel. */
    fun sitzungAufnehmen(sitzung: String) {
        val vorher = ablage.konten
        ablage.konten = Kern.bundAufnehmen(sitzung, vorher.orEmpty())
        kern.sitzungSetzen(sitzung)
        if (vorher != null) nachDemWechsel() else kontovorgabenHolen()
    }

    /** **Beim Wechsel wird nicht abgemeldet** — das verlassene Konto bleibt gueltig fuer den Weg zurueck. */
    fun kontoWechseln(kennung: String) {
        val bund = ablage.konten ?: return
        if (Kern.bundAktiveKennung(bund) == kennung) return
        val neu = Kern.bundWechseln(bund, kennung)
        ablage.konten = neu
        kern.sitzungSetzen(Kern.bundAktives(neu))
        nachDemWechsel()
    }

    /**
     * **Abmelden trifft nur das geltende Konto**, ohne Nachfrage wie auf iOS. Bleiben andere, gilt das
     * naechste; war es das letzte, geht es zurueck zur Serverwahl.
     */
    fun abmelden() {
        lauf.launch { abmeldenJetzt() }
    }

    private suspend fun abmeldenJetzt() {
        runCatching { kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { kern.abmelden().await() } }
        val bund = ablage.konten
        val rest = bund?.let { Kern.bundEntfernt(it, Kern.bundAktiveKennung(it)) }.orEmpty()
        if (rest.isEmpty()) {
            ablage.konten = null
            ablage.sitzung = null
            zwischenstaendeLeeren()
            abgemeldet.intValue++
        } else {
            ablage.konten = rest
            kern.sitzungSetzen(Kern.bundAktives(rest))
            nachDemWechsel()
        }
    }

    /** Was einem Konto gehoert, ist nach dem Wechsel weg; `kontowechsel` baut die Hauptansicht neu. */
    private fun nachDemWechsel() {
        zwischenstaendeLeeren()
        kontovorgabenHolen()
        kontowechsel.intValue++
        lauf.launch { servernameLaden() }
    }

    private fun zwischenstaendeLeeren() {
        // Der Socket gehoert dem vorigen Konto; die Hauptansicht startet ihn fuer das neue.
        lauf.launch { runCatching { kern.fernsteuerungBeenden().await() } }
        startReihen = null
        bibliotheken.clear(); titelSpeicher.clear(); serienSpeicher.clear(); folgenSpeicher.clear(); personenSpeicher.clear()
        servername.value = null
        merkliste.vergessen()
        suche.begriff = ""; suche.treffer = emptyList(); suche.suchmodus = false
        // Vorlage: `AppModel.nachDemWechsel`/Abmelden auf Apple, `Regal.leeren()` — sonst
        // zeigt Watch Next auf dem Fernseher-Startbildschirm weiter die Filme und Serien
        // des vorigen Kontos, sichtbar fuer jeden im Raum.
        de.paulherter.swiftly.tv.TvWeiterschauenRegal.leeren(this)
    }

    /** Assets koennen keinen Dateipfad nennen; `Bundle(path:)` braucht einen. Also einmal entpacken. */
    private fun paketspracheEntpacken(): File {
        val ziel = File(filesDir, "paketsprache")
        ziel.deleteRecursively()
        kopieren("paketsprache", ziel)
        return ziel
    }

    private fun kopieren(pfad: String, ziel: File) {
        val kinder = assets.list(pfad) ?: emptyArray()
        if (kinder.isEmpty()) {
            ziel.parentFile?.mkdirs()
            assets.open(pfad).use { ein -> ziel.outputStream().use { ein.copyTo(it) } }
        } else {
            ziel.mkdirs()
            kinder.forEach { kopieren("$pfad/$it", File(ziel, it)) }
        }
    }

    companion object {
        const val BuildConfigFassung = "1.0.3"
        /** `Fassung.zeile` auf iOS. */
        const val FASSUNGSZEILE = "Swiftly Player 1.0.3 (Build 1)"
        /** Derselbe Schluessel wie in `UserDefaults` auf iOS. */
        const val NACHMELDUNGEN = "nachmeldungen"
    }
}

/**
 * **Plattformablage** — das Gegenstueck zu Keychain und UserDefaults auf Apple.
 * Das Format der Sitzung kommt aus dem Paket; hier wird nur abgelegt.
 */
class Ablage(context: Context) {
    private val prefs = context.getSharedPreferences("swiftly", Context.MODE_PRIVATE)

    /**
     * **Verschluesselt im Android Keystore** — das Gegenstueck zur Keychain. Eine alte Sitzung im
     * Klartext wird beim ersten Lesen umgezogen und geloescht; niemand muss sich neu anmelden.
     */
    var sitzung: String?
        get() {
            prefs.getString("sitzung", null)?.let { klar -> sitzung = klar; return klar }
            return prefs.getString("sitzung.tresor", null)?.let { Tresor.entschluesseln(it) }
        }
        set(wert) {
            val bearbeitung = prefs.edit().remove("sitzung")
            if (wert == null) bearbeitung.remove("sitzung.tresor") else bearbeitung.putString("sitzung.tresor", Tresor.verschluesseln(wert))
            bearbeitung.apply()
        }

    /** Das Kontenbuendel (`Kontenbund`) — verschluesselt wie die Sitzung. */
    var konten: String?
        get() = prefs.getString("konten.tresor", null)?.let { Tresor.entschluesseln(it) }
        set(wert) {
            val bearbeitung = prefs.edit()
            if (wert == null) bearbeitung.remove("konten.tresor") else bearbeitung.putString("konten.tresor", Tresor.verschluesseln(wert))
            bearbeitung.apply()
        }

    fun tresorLesen(schluessel: String): String? = prefs.getString("$schluessel.tresor", null)?.let { Tresor.entschluesseln(it) }
    fun tresorSchreiben(schluessel: String, wert: String?) {
        val bearbeitung = prefs.edit()
        if (wert == null) bearbeitung.remove("$schluessel.tresor") else bearbeitung.putString("$schluessel.tresor", Tresor.verschluesseln(wert))
        bearbeitung.apply()
    }

    var letzterServer: String?
        get() = prefs.getString("letzterServer", null)
        set(wert) { prefs.edit().putString("letzterServer", wert).apply() }

    /** Sortierung, Filter, gewaehlte Bibliothek — dieselben Schluessel wie in UserDefaults auf Apple. */
    fun merkwert(schluessel: String): String? = prefs.getString(schluessel, null)
    fun merken(schluessel: String, wert: String) { prefs.edit().putString(schluessel, wert).apply() }

    fun geraeteID(): String = prefs.getString("de.paulherter.swiftly.deviceID", null)
        ?: UUID.randomUUID().toString().also { prefs.edit().putString("de.paulherter.swiftly.deviceID", it).apply() }
}

/**
 * AES-GCM mit einem Schluessel, der den Keystore nie verlaesst. Laesst sich etwas nicht
 * entschluesseln (Schluessel nach einer Wiederherstellung weg), gilt die Sitzung als nicht da.
 */
internal object Tresor {
    private const val NAME = "de.paulherter.swiftly.sitzung"

    private fun schluessel(): javax.crypto.SecretKey {
        val lager = java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (lager.getKey(NAME, null) as? javax.crypto.SecretKey)?.let { return it }
        val erzeuger = javax.crypto.KeyGenerator.getInstance(android.security.keystore.KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        erzeuger.init(android.security.keystore.KeyGenParameterSpec.Builder(NAME,
                android.security.keystore.KeyProperties.PURPOSE_ENCRYPT or android.security.keystore.KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(android.security.keystore.KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(android.security.keystore.KeyProperties.ENCRYPTION_PADDING_NONE)
            .build())
        return erzeuger.generateKey()
    }

    fun verschluesseln(klar: String): String {
        val chiffre = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        chiffre.init(javax.crypto.Cipher.ENCRYPT_MODE, schluessel())
        val daten = chiffre.doFinal(klar.toByteArray(Charsets.UTF_8))
        return android.util.Base64.encodeToString(chiffre.iv + daten, android.util.Base64.NO_WRAP)
    }

    fun entschluesseln(roh: String): String? = runCatching {
        val alles = android.util.Base64.decode(roh, android.util.Base64.NO_WRAP)
        val chiffre = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        chiffre.init(javax.crypto.Cipher.DECRYPT_MODE, schluessel(), javax.crypto.spec.GCMParameterSpec(128, alles, 0, 12))
        String(chiffre.doFinal(alles, 12, alles.size - 12), Charsets.UTF_8)
    }.getOrNull()
}
