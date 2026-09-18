package de.paulherter.swiftly.tv

import android.content.ContentValues
import android.net.Uri
import androidx.tvprovider.media.tv.TvContractCompat
import androidx.tvprovider.media.tv.WatchNextProgram
import de.paulherter.swiftly.Kachel
import de.paulherter.swiftly.Reihe
import de.paulherter.swiftly.SwiftlyAnwendung

/**
 * Android-Gegenstueck zu Top Shelf auf tvOS — `regalSchreiben()` in `Sources/tvOS/HomeView.swift`
 * und die Erweiterung `Sources/TopShelf/RegalAnbieter.swift`. Dort legt die App bei jedem Laden
 * der Startseite fuer die drei Rubriken „Weiterschauen", „Nächste Folge" und „Zuletzt
 * hinzugefügt" je acht Eintraege in eine geteilte Datei; eine eigene Erweiterung liest sie beim
 * Auffuellen des Startbildschirms.
 *
 * **Android TV hat keine Erweiterung und keinen App-Group-Ordner.** Es gibt stattdessen einen
 * Systemanbieter — `TvContractCompat.WatchNextPrograms` — in den jede App direkt fuer sich selbst
 * schreibt. Diese Datei tut deshalb, was auf Apple zwei Dateien tun: bei jedem Laden der
 * Startseite (`TvStart.kt`) dieselben drei Rubriken in dieselbe Systemzeile „Weiterschauen" auf
 * dem Startbildschirm des Fernsehers legen, acht Eintraege je Rubrik, in derselben Reihenfolge.
 *
 * Zur Unterscheidung dient `Reihe.schluessel` — der rohe, unuebersetzte Name aus
 * `Startreihe.reihentitel` (`Startreihen.swift`), der in jeder Spracheinstellung gleich bleibt.
 *
 * **Stand 15.09.2026, Android 14 / Google TV geprueft:** Watch Next bleibt fuer jede App offen,
 * ohne besondere Berechtigung. Anders der „Channels"-Weg (`TvContractCompat.Channels` /
 * `PreviewPrograms`, die eigene Kanalzeile unterhalb von Watch Next) — der verlangt inzwischen
 * die Systemberechtigung `WRITE_EPG_DATA`, die Drittanbieter-Apps nicht mehr bekommen. Deshalb
 * ausschliesslich Watch Next, kein eigener Kanal.
 *
 * Fehler hier duerfen die App nie stoeren: jeder Aufruf laeuft in `runCatching`, und der
 * Zugriff auf den Anbieter passiert nur, wenn `aktualisieren`/`leeren` selbst schon abseits des
 * Hauptthreads laufen (siehe die Aufrufstelle in `TvStart.kt`).
 */
internal object TvWeiterschauenRegal {
    private const val SCHLUESSEL_WEITERSCHAUEN = "Weiterschauen"
    private const val SCHLUESSEL_NAECHSTE_FOLGE = "Nächste Folge"
    private const val SCHLUESSEL_ZULETZT = "Zuletzt hinzugefügt"

    /** Dieselbe Adresse wie im Top Shelf auf tvOS (`RegalAnbieter.swift`: `swiftly://titel/<id>"`). */
    private fun adresse(id: String): Uri = Uri.parse("swiftly://titel/$id")

    /**
     * Schreibt die drei Rubriken aus den schon geladenen Startseiten-Reihen ins Watch-Next-Regal.
     * `reihen` ist genau das, was `TvStart.kt` gerade fuer die Startseite selbst haelt — dieselbe
     * Quelle, kein zweiter Abruf.
     */
    fun aktualisieren(app: SwiftlyAnwendung, reihen: List<Reihe>?) {
        if (!app.istFernseher || reihen == null) return
        runCatching {
            val loeser = app.contentResolver

            // **Bestehende Eintraege nicht loeschen und neu anlegen** — das liesse den Eintrag auf
            // dem Startbildschirm kurz verschwinden. `internalProviderId` traegt die Jellyfin-ID
            // und unterscheidet, was zu aktualisieren und was veraltet ist. Der Anbieter zeigt
            // ohnehin nur die Zeilen dieser App: eine fremde Watch-Next-Zeile kaeme hier nie an.
            val bestehend = mutableMapOf<String, Long>()
            loeser.query(TvContractCompat.WatchNextPrograms.CONTENT_URI,
                arrayOf(TvContractCompat.WatchNextPrograms._ID,
                        TvContractCompat.WatchNextPrograms.COLUMN_INTERNAL_PROVIDER_ID),
                null, null, null)?.use { c ->
                val idxId = c.getColumnIndex(TvContractCompat.WatchNextPrograms._ID)
                val idxProv = c.getColumnIndex(TvContractCompat.WatchNextPrograms.COLUMN_INTERNAL_PROVIDER_ID)
                while (c.moveToNext()) {
                    val jellyfinId = c.getString(idxProv) ?: continue
                    bestehend[jellyfinId] = c.getLong(idxId)
                }
            }

            // Dieselbe Reihenfolge wie auf der Startseite: Weiterschauen, dann Nächste Folge,
            // dann Zuletzt hinzugefügt — leere Rubriken fallen weg, wie in `regalSchreiben()`.
            val rubriken = listOfNotNull(
                reihen.firstOrNull { it.schluessel == SCHLUESSEL_WEITERSCHAUEN }
                    ?.let { it to TvContractCompat.WatchNextPrograms.WATCH_NEXT_TYPE_CONTINUE },
                reihen.firstOrNull { it.schluessel == SCHLUESSEL_NAECHSTE_FOLGE }
                    ?.let { it to TvContractCompat.WatchNextPrograms.WATCH_NEXT_TYPE_NEXT },
                reihen.firstOrNull { it.schluessel == SCHLUESSEL_ZULETZT }
                    ?.let { it to TvContractCompat.WatchNextPrograms.WATCH_NEXT_TYPE_NEW })

            var reihenfolge = 0
            val geschrieben = mutableSetOf<String>()
            rubriken.forEach { (reihe, watchNextTyp) ->
                reihe.kacheln.take(8).forEach { k ->
                    geschrieben += k.id
                    val werte = werte(k, reihe.quer, watchNextTyp, reihenfolge++)
                    val vorhandeneZeile = bestehend[k.id]
                    if (vorhandeneZeile != null) {
                        loeser.update(mitId(vorhandeneZeile), werte, null, null)
                    } else {
                        loeser.insert(TvContractCompat.WatchNextPrograms.CONTENT_URI, werte)
                    }
                }
            }
            // Veraltet: stand vorher im Regal, gehoert jetzt zu keiner der drei Rubriken mehr —
            // etwa fertig geschaut, oder aus der Startseite gefallen.
            bestehend.forEach { (jellyfinId, zeile) ->
                if (jellyfinId !in geschrieben) loeser.delete(mitId(zeile), null, null)
            }
        }
    }

    /** Vorlage: `Regal.leeren()` in `Regalvorschau.swift` — beim Abmelden und beim Kontowechsel. */
    fun leeren(app: SwiftlyAnwendung) {
        if (!app.istFernseher) return
        runCatching {
            app.contentResolver.delete(TvContractCompat.WatchNextPrograms.CONTENT_URI, null, null)
        }
    }

    private fun mitId(zeile: Long) =
        TvContractCompat.WatchNextPrograms.CONTENT_URI.buildUpon().appendPath(zeile.toString()).build()

    private fun werte(k: Kachel, quer: Boolean, watchNextTyp: Int, reihenfolge: Int): ContentValues {
        val typ = if (k.typ == "Episode") TvContractCompat.PreviewPrograms.TYPE_TV_EPISODE
                  else TvContractCompat.PreviewPrograms.TYPE_MOVIE
        val bau = WatchNextProgram.Builder()
            .setType(typ)
            .setWatchNextType(watchNextTyp)
            .setTitle(k.name)
            .setInternalProviderId(k.id)
            .setIntentUri(adresse(k.id))
            // Steuert nur die Reihenfolge **innerhalb** dieser App-Zeile — dieselbe wie auf der
            // Startseite. Neuer als der letzte Eintrag der vorigen Rubrik, sonst mischt Android
            // sie nach eigenem Ermessen.
            .setLastEngagementTimeUtcMillis(System.currentTimeMillis() - reihenfolge * 1000L)
        // Folgentitel/Serienname wie auf tvOS' Top Shelf: `unterzeile` traegt bei Folgen das
        // Staffel-/Folgenkuerzel, `name` schon den Serientitel (siehe `kachel()` in `Kern.swift`).
        k.unterzeile?.let { bau.setEpisodeTitle(it) }
        (if (quer) k.quer ?: k.plakat else k.plakat)?.let { bau.setPosterArtUri(Uri.parse(it)) }
        // Echte Millisekunden fuer den Fortschrittsbalken, nicht nur den Anteil — sonst zeigte
        // der Systemstarter eine erfundene Restzeit an. Siehe `Kachelantwort` in `Kern.swift`.
        val laufzeit = k.laufzeitSekunden
        val position = k.positionSekunden
        if (watchNextTyp == TvContractCompat.WatchNextPrograms.WATCH_NEXT_TYPE_CONTINUE
            && laufzeit != null && laufzeit > 0 && position != null && position > 0) {
            bau.setDurationMillis((laufzeit * 1000).toInt())
            bau.setLastPlaybackPositionMillis((position * 1000).toInt())
        }
        return bau.build().toContentValues()
    }
}
