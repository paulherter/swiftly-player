import JellyfinKit
import CGtk
import Foundation

/// **Eine Datei sagt der App, wohin sie gehen soll.**
///
/// Das Gegenstück zu `Fensterabzug` auf dem Mac (`touch abzug.jetzt`), nur
/// andersherum: Bilder macht auf Linux `spectacle`, was fehlt, ist der Weg
/// *zur* Seite.
///
/// **Warum es das braucht.** Eine Sitzung soll nachsehen, bevor sie etwas
/// meldet — so steht es im Übernahmeskill, und der Blick kostet dreißig
/// Sekunden gegen eine ganze Rückfragerunde. Auf Linux ging das nicht:
/// `ydotool` erreicht die App auf dieser Wayland-Sitzung nicht, egal mit
/// welchen Koordinaten. Am 13.09.2026 sind dadurch zwei Behebungen
/// ausgeliefert worden, die gar nicht griffen, und drei Seiten galten als
/// angepasst, die es nicht waren. Blind bauen ist teurer als das hier.
///
/// **Nur im Debug-Bau.** Im Auslieferungsbau gibt es die Datei nicht und den
/// Takt auch nicht — eine App, die auf Zuruf durch ihre Seiten springt, ist
/// eine Fernsteuerung, die niemand bestellt hat.
///
/// ```bash
/// echo profil > /tmp/swiftly-zeige      # Profil
/// echo serie:<id> > /tmp/swiftly-zeige  # eine Serienseite
/// echo reiter:besetzung > /tmp/swiftly-zeige
/// ```
/// Der Takt selbst — als freie Funktion, weil ein C-Zeiger keine Closure mit
/// Umgebung annimmt.
private nonisolated(unsafe) let pultTakten: @convention(c) (gpointer?) -> gboolean = { daten in
    guard let daten else { return 0 }
    let app = Unmanaged<App>.fromOpaque(daten).takeUnretainedValue()
    guard let wort = try? String(contentsOf: Fernsteuerpult.anstoss, encoding: .utf8)
    else { return 1 }
    try? FileManager.default.removeItem(at: Fernsteuerpult.anstoss)
    app.fernbefehl(wort.trimmingCharacters(in: .whitespacesAndNewlines))
    return 1
}

enum Fernsteuerpult {

    /// Unter Windows ist `C:\\tmp` ohne Administrator nicht beschreibbar;
    /// dort liegt die Datei im Temp-Ordner des Nutzers.
    #if os(Windows)
    static let anstoss = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("swiftly-zeige")
    #else
    static let anstoss = URL(fileURLWithPath: "/tmp/swiftly-zeige")
    #endif

    /// Anderthalb Sekunden Takt — dieselbe Zahl wie auf dem Mac, aus
    /// demselben Grund: langsam genug, um im Betrieb nicht aufzufallen,
    /// schnell genug, um nicht darauf zu warten.
    static func lauschen(_ app: App) {
        #if DEBUG
        _ = g_timeout_add_seconds(2, pultTakten, Unmanaged.passUnretained(app).toOpaque())
        #endif
    }
}

extension App {

    /// Führt einen Befehl aus dem ``Fernsteuerpult`` aus.
    func fernbefehl(_ wort: String) {
        let teile = wort.split(separator: ":", maxSplits: 1).map(String.init)
        switch teile.first {
        case "start":       zeige(.start)
        case "filme":       zeige(.filme)
        case "serien":      zeige(.serien)
        case "suche":       zeige(.suche)
        case "merkliste":   zeige(.merkliste)
        case "downloads":   zeige(.downloads)
        case "profil":      unterseiteOeffnen(.profil)
        case "einstellungen": unterseiteOeffnen(.einstellungen)
        case "wiedergabe":  unterseiteOeffnen(.wiedergabe)
        case "darstellung": unterseiteOeffnen(.darstellung)
        case "quickconnect": unterseiteOeffnen(.quickConnect)
        case "zurueck":     zurueck()

        /// Den ersten Titel einer Reihe öffnen — ohne seine Kennung zu kennen.
        case "ersterTitel":
            if let erster = rasterItems[bereich]?.first ?? letzteStartreihe.first {
                oeffne(erster)
            }

        /// Den ersten Titel der ersten Startreihe abspielen — der einzige
        /// Weg in den Player ohne Klick.
        case "spielen":
            if let erster = letzteStartreihe.first { starte(erster) }

        /// Nennt die ersten Titel der ersten Startreihe — damit ein Messlauf
        /// weiss, was `spielen` starten würde, bevor er es tut.
        case "startreihe":
            print("[Fern] Startreihe: " + letzteStartreihe.prefix(5)
                .map { ($0.seriesName ?? $0.name) + " (\($0.type ?? "?"))" }.joined(separator: " | "))
            fflush(nil)

        /// Anhalten oder weiter, wie die Leertaste — ein Messlauf hält gleich
        /// an, damit die gemerkte Stelle beim Server stehen bleibt.
        case "pause":
            guard laufenderTitel != nil else { break }
            abspieler.umschalten()
            spielstand.laeuft.toggle()
            spielerAbspielzeichen?.setzen(spielstand.laeuft)
            medienstandMelden()

        /// Die Steuerung einblenden — sie geht sonst nach ein paar Sekunden
        /// von selbst weg, und ein Bildschirmabzug bekaeme sie nie zu sehen.
        /// Die Aktualisierungssuche anstossen, ohne durch die Einstellungen
        /// zu klicken — nur Windows, dort gibt es die Zeile.
        case "update":
            #if os(Windows)
            aktualisierungSuchen()
            #else
            // **Auf Linux ohne Oberflaeche, aber mit derselben Abfrage.**
            // Den Knopf gibt es hier nicht; die Kette dahinter — GitHub
            // fragen, die Antwort lesen, den Installer heraussuchen,
            // vergleichen — ist dieselbe und laesst sich so pruefen, ohne
            // auf einen Windows-Rechner angewiesen zu sein.
            Task.detached {
                do {
                    if let stand = try await Aktualisierung.suchen() {
                        Protokoll.schreib("[Update] neuer Stand \(stand.fassung), Bau \(stand.bau.map(String.init) ?? "—"), \(stand.groesse) Bytes, \(stand.adresse.lastPathComponent)")
                    } else {
                        Protokoll.schreib("[Update] nichts Neueres (hier \(Fassung.voll))")
                    }
                } catch {
                    Protokoll.schreib("[Update] Abfrage fehlgeschlagen: \(error)")
                }
            }
            #endif

        case "steuerung":  steuerungZeigen()

        /// Den Player wieder schliessen.
        case "spielerZu":  spielerSchliessen()

        /// Die Wiedergabetafel im Player auf- und zuklappen.
        case "spurwahl":   ebeneOeffnen(.spuren)
        case "einstellungenEbene": ebeneOeffnen(.einstellungen)
        case "folgenEbene": ebeneOeffnen(.folgen)
        case "ebeneZu":    ebeneSchliessen()

        /// Den offenen Titel laden, wie der Knopf „Laden" in der Tafel.
        case "laden":
            if let t = letzterVollerTitel {
                ladenAnstossen(t, quelle: t.mediaSources?.first,
                               bytes: t.mediaSources?.first?.size ?? 0)
            }

        /// An eine Stelle springen (`stelle:1331`) — ein Messlauf stellt so
        /// die gemerkte Stelle wieder her, bevor er den Player schliesst.
        case "stelle":
            if laufenderTitel != nil, teile.count > 1, let s = Double(teile[1]) { springe(auf: s) }

        /// Einen Reiter der Serienseite wählen.
        case "reiter":
            switch teile.count > 1 ? teile[1] : "" {
            case "folgen":     reiterWaehlen?(.folgen)
            case "besetzung":  reiterWaehlen?(.besetzung)
            case "aehnliches": reiterWaehlen?(.aehnliches)
            default: break
            }

        /// **Einen Titel abspielen, der die Abspielkette ganz durchläuft** —
        /// H.264 oder HEVC, Ton als AAC/AC3/DTS, eingebettete Untertitel.
        /// Gebaut am 16.09.2026, um zu belegen, dass der gekürzte Windows-
        /// Installer noch spielt. Ins Protokoll kommen nur Codecs und die
        /// Kennung, keine Adresse.
        case "pruefspielen":
            guard let client else { break }
            Task.detached { [self] in
                let liste = (try? await client.items(limit: 200, recursive: true,
                                                     includeItemTypes: ["Movie", "Episode"]))?.items ?? []
                var ersatz: Item?
                for kurz in liste {
                    guard let voll = try? await client.item(id: kurz.id),
                          let stroeme = voll.mediaSources?.first?.mediaStreams else { continue }
                    let bild = stroeme.first { $0.type == "Video" }?.codec ?? ""
                    let ton = stroeme.first { $0.type == "Audio" }?.codec ?? ""
                    let texte = stroeme.filter { $0.type == "Subtitle" && $0.isExternal != true }
                        .compactMap(\.codec)
                    guard ["h264", "hevc"].contains(bild),
                          ["aac", "ac3", "eac3", "dts"].contains(ton) else { continue }
                    if texte.contains(where: { ["ass", "ssa", "pgssub"].contains($0) }) {
                        print("[Pult] pruefspielen \(voll.id): \(voll.mediaSources?.first?.container ?? "?") \(bild) \(ton) Untertitel \(texte)")
                        fflush(nil)
                        aufHauptfaden { self.spielerOeffnen(voll, ab: 120) }
                        return
                    }
                    if ersatz == nil, !texte.isEmpty { ersatz = voll }
                }
                if let voll = ersatz {
                    print("[Pult] pruefspielen Ersatz \(voll.id), kein ASS/PGS gefunden")
                    fflush(nil)
                    aufHauptfaden { self.spielerOeffnen(voll, ab: 120) }
                } else {
                    print("[Pult] pruefspielen: nichts Passendes unter \(liste.count) Titeln")
                    fflush(nil)
                }
            }

        /// **Folgenwechsel messen** (Audit T2-H1/H2/M3). `folge:weiter`
        /// spielt eine Folge mit Nachfolger, `folge:letzte` eine ohne,
        /// `folge:zu` oeffnet eine und schliesst sofort — bevor der Plan da
        /// ist, `folge:seite` spielt sie von der Serienseite aus.
        /// `naechsteDoppelt` drueckt „Nächste Folge" zweimal hintereinander.
        case "folge":
            guard let client else { break }
            let art = teile.count > 1 ? teile[1] : "weiter"
            Task.detached { [self] in
                let liste = (try? await client.items(limit: art == "abspann" ? 400 : 60, recursive: true,
                                                     includeItemTypes: ["Episode"]))?.items ?? []
                for folge in liste {
                    // Ohne Laufzeit ist es eine fehlende Folge ohne Datei.
                    guard let serie = folge.seriesId, folge.runTimeTicks != nil else { continue }
                    let nach = (try? await client.folgeNach(itemID: folge.id, seriesID: serie)) ?? nil
                    guard (art == "letzte") == (nach == nil) else { continue }
                    // `folge:abspann` sucht eine mit Abspann bis ans Ende und
                    // startet sechs Sekunden davor (Stufe 3, Einblendung).
                    var ab: Double = 30
                    if art == "abspann" {
                        let marken = await client.abschnitte(fuer: folge.id)
                        guard let abspann = marken.first(where: { $0.art == .abspann }),
                              let ticks = folge.runTimeTicks,
                              abspann.bis >= Double(ticks) / 10_000_000 - Abschnittslogik.abspannToleranz
                        else { continue }
                        ab = max(0, abspann.von - 6)
                        print("[Pult] abspann \(Int(abspann.von))-\(Int(abspann.bis)) s")
                    }
                    print("[Pult] folge:\(art) \(folge.id) naechste \(nach?.id ?? "keine")")
                    fflush(nil)
                    // `folge:seite` geht erst auf die Serienseite, damit
                    // sich das Neuladen nach dem Player messen laesst.
                    if art == "seite" {
                        aufHauptfaden { self.oeffne(folge) }
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                    }
                    let start = ab
                    aufHauptfaden {
                        self.spielerOeffnen(folge, ab: start)
                        if art == "zu" { self.spielerSchliessen() }
                    }
                    return
                }
                print("[Pult] folge:\(art): nichts unter \(liste.count) Folgen")
                fflush(nil)
            }

        /// Die offene Detailseite auf eine Stelle scrollen (`scroll:600`) oder
        /// nur ihre Stelle ins Protokoll schreiben (`scroll`).
        case "scroll":
            if teile.count > 1, let wert = Double(teile[1]), let detailScroller,
               let senkrecht = gtk_scrolled_window_get_vadjustment(OpaquePointer(detailScroller)) {
                gtk_adjustment_set_value(senkrecht, wert)
            }
            print("[Pult] scroll \(Int(scrollstand()))")
            fflush(nil)

        #if DEBUG
        /// Meldungen an den Server haengen lassen (`meldungen:haengen`) oder
        /// wieder normal senden (`meldungen:normal`) — siehe ``Meldeprobe``.
        case "meldungen":
            Meldeprobe.haengen = teile.count > 1 && teile[1] == "haengen"
            print("[Pult] meldungen haengen \(Meldeprobe.haengen)")
            fflush(nil)
        #endif

        /// Zeitleiste ins Protokoll (Stelle, VLC-Zeit, laeuft).
        case "stelle":
            print("[Pult] stelle \(String(format: "%.1f", spielstand.position)) vlc \(String(format: "%.1f", abspieler.position)) laeuft \(abspieler.laeuft)")
            fflush(nil)

        /// Pause/Weiter wie die Leertaste, Sprung wie ein Fernbefehl.
        case "umschalten":
            abspieler.umschalten()
        case "springeAuf":
            if teile.count > 1, let wert = Double(teile[1]) { springe(auf: wert) }

        /// Die Stelle, die der Server fuer einen Titel kennt (`serverstand:<id>`).
        case "serverstand":
            guard let client, teile.count > 1 else { break }
            let kennung = teile[1]
            Task.detached {
                let titel = try? await client.item(id: kennung)
                let ticks = titel?.userData?.playbackPositionTicks ?? -1
                print("[Pult] serverstand \(kennung) \(ticks) Ticks = \(String(format: "%.1f", Double(ticks) / 10_000_000)) s")
                fflush(nil)
            }

        /// Eine Taste wie vom Fenster (`taste:eingabe`, `taste:escape`) —
        /// ydotool erreicht die App unter Wayland nicht.
        case "taste":
            let wert: UInt32 = teile.count > 1 && teile[1] == "escape" ? 0xFF1B : 0xFF0D
            let verbraucht = taste(wert, strg: false)
            print("[Pult] taste \(teile.count > 1 ? teile[1] : "eingabe") verbraucht \(verbraucht)")
            fflush(nil)

        /// „Nächste Folge automatisch": `an`, `aus`, `frei` (nie umgelegt).
        case "automatisch":
            let w = teile.count > 1 ? teile[1] : "frei"
            wahlen.naechsteAutomatischGewaehlt = w == "an" ? true : w == "aus" ? false : nil
            print("[Pult] automatisch \(w), Konto \(naechsteAutomatischKonto.map { String($0) } ?? "nil"), gilt \(naechsteAutomatisch)")
            fflush(nil)

        case "naechsteDoppelt":
            naechsteFolge()
            naechsteFolge()

        /// Den ersten fertigen Download aus der Datei abspielen.
        /// **Eine beliebige Datei spielen** — `dateispielen:/tmp/probe.mkv`.
        /// Ohne Pfad der erste Download. Der Weg ohne Server und ohne Plan:
        /// damit laesst sich eine Datei mit bekannten Eigenschaften messen,
        /// ohne einen fremden Sehstand anzufassen.
        case "dateispielen" where teile.count > 1:
            let pfad = teile[1]
            // Auch eine Netzadresse: derselbe Weg, aber mit den Netzoptionen
            // — so laesst sich messen, was ein laufender Strom beim Anhalten
            // kostet, ohne einen fremden Sehstand anzufassen.
            if pfad.hasPrefix("http") {
                Protokoll.schreib("[Pult] dateispielen \(pfad)")
                let item = Item(id: "probe", name: "Probe", type: "Movie")
                spielerOeffnen(item, ab: 0, ausDatei: URL(string: pfad)!)
                break
            }
            guard FileManager.default.fileExists(atPath: pfad) else {
                print("[Pult] dateispielen: keine Datei \(pfad)"); fflush(nil); break
            }
            print("[Pult] dateispielen \(pfad)"); fflush(nil)
            let item = Item(id: "probe", name: URL(fileURLWithPath: pfad).lastPathComponent,
                            type: "Movie")
            spielerOeffnen(item, ab: 0, ausDatei: URL(fileURLWithPath: pfad))

        case "dateispielen":
            if let p = downloads.posten.first(where: { downloads.datei(fuer: $0.id) != nil }) {
                print("[Pult] dateispielen \(p.id) \(p.container ?? "?")")
                fflush(nil)
                downloadSpielen(p)
            } else {
                print("[Pult] dateispielen: kein Download mit Datei")
                fflush(nil)
            }

        /// **Spurwahl messen** (Stufe 4). `spurlauf:<Serie>:<Folge>` spielt
        /// die n-te Folge (ab 1) der ersten Serie, die die Suche findet —
        /// geschrieben `spurlauf:Adults/2`.
        case "spurlauf":
            guard let client, teile.count > 1 else { break }
            let angabe = teile[1].split(separator: "/").map(String.init)
            let name = angabe.first ?? ""
            let nummer = angabe.count > 1 ? Int(angabe[1]) ?? 1 : 1
            Task.detached { [self] in
                let treffer = (try? await client.suche(name)) ?? []
                guard let serie = treffer.first(where: { $0.type == "Series" }) else {
                    print("[Pult] spurlauf: keine Serie \(name)"); fflush(nil); return
                }
                let folgen = ((try? await client.folgen(seriesID: serie.id)) ?? [])
                    .filter { $0.runTimeTicks != nil }
                guard folgen.count >= nummer else {
                    print("[Pult] spurlauf: \(folgen.count) Folgen"); fflush(nil); return
                }
                let folge = folgen[nummer - 1]
                print("[Pult] spurlauf \(serie.name) \(folge.folgenkuerzel ?? "") \(folge.id)")
                fflush(nil)
                aufHauptfaden { self.spielerOeffnen(folge, ab: 60) }
            }

        /// Die Spuren, wie die Tafel sie zeigt, samt Wahl.
        case "spuren":
            let jetztTon = abspieler.tonspur, jetztUt = abspieler.untertitelspur
            for s in tonspurnamen() { print("[Pult] Ton \(s.kennung)\(s.kennung == jetztTon ? " *" : "") \(s.name)") }
            for s in untertitelnamen() { print("[Pult] Untertitel \(s.kennung)\(s.kennung == jetztUt ? " *" : "") \(s.name)") }
            print("[Pult] spuren gemeldet \(spurlage.gemeldet.ton.map(String.init) ?? "—")/\(spurlage.gemeldet.untertitel.map(String.init) ?? "—")")
            fflush(nil)

        /// Eine Wahl wie aus der Tafel: `waehle:ton/<n>`, `waehle:ut/<n>`
        /// (n-te Zeile ab 1) oder `waehle:ut/aus`.
        case "waehle":
            let teile = [teile[0]] + (teile.count > 1 ? teile[1].split(separator: "/").map(String.init) : [])
            guard teile.count > 2 else { break }
            if teile[1] == "ton", let n = Int(teile[2]) {
                let liste = tonspurnamen()
                if liste.indices.contains(n - 1) { tonspurGewaehlt(liste[n - 1].kennung) }
            } else if teile[1] == "ut" {
                if teile[2] == "aus" { untertitelGewaehlt(nil) }
                else if let n = Int(teile[2]) {
                    let liste = untertitelnamen()
                    if liste.indices.contains(n - 1) { untertitelGewaehlt(liste[n - 1].kennung) }
                }
            }

        /// „Nächste Folge", wie der Knopf.
        case "naechste":
            naechsteFolge()

        /// „Fortschritt auf Kacheln" umlegen wie der Schalter
        /// (`fortschritt:an|aus`) und zaehlen, wie viele Balken seit dem
        /// letzten Aufruf gelegt wurden.
        case "fortschritt":
            if teile.count > 1 {
                wahlen.fortschrittAufKacheln = teile[1] == "an"
                startseiteLaden()
            }
            print("[Pult] fortschritt \(wahlen.fortschrittAufKacheln) balken \(Pruefzaehler.balken)"
                  + " erste Reihe \(letzteStartreihe.count), davon angefangen \(letzteStartreihe.filter { $0.gesehenerAnteil != nil }.count)")
            Pruefzaehler.balken = 0
            fflush(nil)

        #if DEBUG
        /// **N7 ohne zweites Geraet:** zwei erfundene Sitzungen anbieten und
        /// die Zeile druecken. Die Kennungen gibt es nicht; `uebernahme:2`
        /// waehlt danach das zweite — der Server lehnt ab, der Fehler muss
        /// in der Zeile stehen.
        case "uebernahme":
            uebernahmeprobe(teile.count > 1 ? Int(teile[1]) : nil)
        #endif

        /// Die erste eingebettete Untertitelspur einschalten.
        case "untertitel":
            let spuren = abspieler.untertitelspuren.filter { $0.kennung >= 0 }
            if let erste = spuren.first { abspieler.setzeUntertitel(erste.kennung) }
            print("[Pult] untertitel: \(spuren.count) Spuren, jetzt \(abspieler.untertitelspur)")
            fflush(nil)

        /// Was gerade läuft, in Zahlen — Bild, Ton, Bilder im Speicher.
        case "bericht":
            let z = abspieler.zaehlwerte
            print("[Pult] bericht: laeuft \(abspieler.laeuft) position \(Int(abspieler.position)) " +
                  "videoBloecke \(z?.videoBloecke ?? 0) gezeigt \(z?.gezeigt ?? 0) " +
                  "tonBloecke \(z?.tonBloecke ?? 0) tonGespielt \(z?.tonGespielt ?? 0) " +
                  "tonspuren \(abspieler.tonspuren.count) untertitel \(abspieler.untertitelspur) " +
                  "weg \(laufenderPlan.map { "\($0.method)" } ?? "Datei") " +
                  "bilder \(Bildspeicher.anzahl) \(Pruefzaehler.bilder)")
            fflush(nil)

        /// Die erste Person der Besetzung öffnen.
        case "erstePerson":
            // **Der volle Satz, nicht der Stapeleintrag.** Auf dem Stapel
            // liegt die magere Kachel, und die traegt keine Besetzung — der
            // Befehl lief deshalb still ins Leere.
            if let titel = letzterVollerTitel ?? seitenstapel[bereich]?.last,
               let erste = titel.darsteller.first {
                oeffnePerson(erste, herkunft: titel.name)
            }
        default: break
        }
    }
}

/// Welche Bildformate angekommen sind und ob GTK sie lesen konnte — nur im
/// Debug-Bau gezählt, für ``App/fernbefehl(_:)`` „bericht".
enum Pruefzaehler {
    nonisolated(unsafe) static var bilder: [String: Int] = [:]
    /// Gelegte Fortschrittsbalken — Fernsteuerpult `fortschritt`.
    nonisolated(unsafe) static var balken = 0

    static func bild(_ daten: Data, gelesen: Bool) {
        let kopf = [UInt8](daten.prefix(12))
        let art: String
        if kopf.starts(with: [0xFF, 0xD8]) { art = "jpeg" }
        else if kopf.starts(with: [0x89, 0x50, 0x4E, 0x47]) { art = "png" }
        else if kopf.count >= 12, kopf[8] == 0x57, kopf[9] == 0x45, kopf[10] == 0x42, kopf[11] == 0x50 { art = "webp" }
        else { art = "anderes" }
        bilder["\(art)-\(gelesen ? "ok" : "fehler")", default: 0] += 1
    }
}
