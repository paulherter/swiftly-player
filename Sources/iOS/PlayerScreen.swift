import JellyfinKit
import OSLog
import SwiftUI

/// Der Player.
///
/// Aufbau: Steuerung mittig zwischen Titelzeile und Regler, darunter ein
/// Schleier — ohne den verschwinden weiße Symbole in hellen Szenen.
/// Doppeltippen links/rechts spult, einmal tippen blendet um.
struct PlayerScreen: View {
    let model: AppModel
    let startAt: Double

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var lebenslage

    // Laufender Titel — ändert sich, wenn zur nächsten Folge gewechselt wird.
    @State private var item: Item
    @State private var plan: PlaybackPlan

    @State private var surface: VLCPlayerView?
    @State private var pipAvailable = false
    @State private var stelltWiederHer = false
    /// Läuft gerade im kleinen Fenster.
    @State private var imKleinenFenster = false
    @State private var erstesBildDa = false
    /// Wird beim Oeffnen gedreht? Muss vorher feststehen — steht die Lage
    /// schon richtig, feuert gar kein Uebergang.
    @State private var drehungErwartet = false
    @State private var drehungFertig = false
    /// Wann die Drehung angeordnet wurde — nur, um ihre Dauer am Geraet zu
    /// messen. Der Simulator sagt 300 ms Animationsdauer und 349 ms bis zur
    /// `completion`; ob das Telefon dasselbe tut, steht damit im Protokoll.
    @State private var drehungAngefordert: Date?
    @State private var seitStart = Date()
    /// Einmal je Titel: die Spurvorwahl anwenden.
    @State private var spurenGesetzt = false
    /// Dem Server ist gesagt worden, dass dieser Titel begonnen hat.
    /// Beim Folgenwechsel neu zu setzen — siehe `Wiedergabetakt.neuerTitel`.
    @State private var startGemeldet = false
    /// Zaehlt bei jedem Titelwechsel hoch. Die Schleife setzt daraufhin ihren
    /// Stand ueber `Wiedergabetakt.neuerTitel` zurueck — von Hand ginge es
    /// auch, aber dann staende die Regel wieder an zwei Stellen.
    @State private var titelwechsel = 0
    @State private var hinweis: String?

    @State private var position: Double = 0
    @State private var dauer: Double = 0
    @State private var laeuft = true
    @State private var amSchieben = false
    @State private var steuerungSichtbar = true
    @State private var letzterTipp: Date?
    @State private var letzteSeite = 0

    /// Sichtbar heisst: gewollt, Bild steht, kein Menue davor.
    ///
    /// Und nicht auf dem Fernseher: dort steuert `AVPlayerViewController`, und
    /// zwei Steuerungen uebereinander wuerden sich gegenseitig treffen.
    private var steuerungDa: Bool {
        schleierDa && !zeigeEinstellungen
    }

    /// **Die Abdunklung bleibt unter dem Wiedergabemenue stehen.**
    ///
    /// Sie hing frueher mit an `!zeigeEinstellungen`, war unter dem Blatt also
    /// gar nicht da — und musste beim Schliessen erst wieder hochfahren. In
    /// dem Fenster sah man ungedaempftes Video, heller als vorher *und*
    /// nachher. Paul: „der Player ist erst nicht da und blendet sich dann erst
    /// selber rein. Der muesste aber die ganze Zeit dableiben."
    ///
    /// Sichtbar aendert das nichts, solange das Blatt offen ist: es deckt mit
    /// 0,97 ohnehin alles darunter ab. Kopf, Fuss und Mittelsteuerung weichen
    /// weiterhin — sie wuerden durch das Blatt scheinen, siehe unten.
    private var schleierDa: Bool {
        steuerungSichtbar && bildFrei && !imKleinenFenster && airplayPlan == nil
    }

    /// **Das Bild ist frei, wenn es steht — und wenn es richtig herum steht.**
    ///
    /// Seit der Player pausiert oeffnet und sofort springt, kommt das erste
    /// Bild bei rund +0,9 s. Die Drehung ins Querformat dauert 300 ms und
    /// beginnt erst mit `onAppear`; vorher hat die erste Sekunde vom
    /// Filmanfang sie kaschiert. Paul sah das Bild dadurch kurz im Hochformat.
    ///
    /// `drehungFertig` kommt aus `Drehhorcher`, also vom Uebergangskoordinator
    /// — dem einzigen Signal, das das **Ende** der Drehung meldet. Geometrie
    /// und `interfaceOrientation` springen schon nach gut dreissig
    /// Millisekunden auf die Endwerte und taugen dafuer nicht; das ist
    /// gemessen, siehe `Drehhorcher`.
    ///
    /// Ohne erwartete Drehung ist die Bedingung genau die alte.
    private var bildFrei: Bool {
        erstesBildDa && (!drehungErwartet || drehungFertig)
    }

    /// Beobachtet, ob der Ton auf ein AirPlay-Geraet umgestellt wurde.
    @State private var fernziel = Fernziel()
    /// Gesetzt, solange der Film ueber `AVPlayer` auf dem Fernseher laeuft.
    @State private var airplayPlan: PlaybackPlan?
    /// Die Stelle, an der VLC abgegeben hat.
    @State private var airplayAb: Double = 0
    @State private var sprungAnzeige: (richtung: Int, sekunden: Int)?
    /// Zaehlen die Ausloesungen je Richtung. Der Knopf dreht sich dadurch
    /// bei jedem Druck ein Stueck weiter, statt nur einmal.
    @State private var taktZurueck = 0
    @State private var taktVor = 0
    @State private var ausblendMarke = 0
    /// Nach einem Sprung kurz nicht überschreiben, sonst springt der Regler
    /// auf den alten Wert zurück, bevor VLC nachgezogen hat.
    @State private var sprungBis: Date?
    @State private var zuletztGeschoben: Date?

    @State private var zeigeEinstellungen = false
    @State private var tempo: Float = 1.0
    @State private var schlafminuten: Int?
    @State private var schlafAufgabe: Task<Void, Never>?
    /// Kommt aus den Einstellungen, nicht mehr aus dem Player.
    @AppStorage("querformatFest") private var querformatFest = true

    @State private var naechsteFolge: Item?
    /// Vorspann, Rückblick, Abspann — leer, wenn der Server nichts weiß.
    ///
    /// Steht die Liste leer, ändert sich gegenüber früher **nichts**: dann
    /// entscheidet allein die Restzeitregel, wann „Nächste Folge" erscheint.
    // `JellyfinKit.` ausgeschrieben: `Abschnitt` heisst in
    // `BrowseViews.swift` schon eine Ansicht, und die hiess zuerst so.
    @State private var abschnitte: [JellyfinKit.Abschnitt] = []
    @State private var wechselt = false
    /// Sperrbildschirm, Kontrollzentrum, Kopfhörertasten und Anrufe.
    @State private var zentrale = Wiedergabezentrale()

    /// Breite des Fensters. Im geteilten Bildschirm bleiben davon 320 übrig,
    /// und darin läuft eine Steuerung, die für 844 gebaut ist, aus dem Bild.
    @State private var fensterbreite: CGFloat = 0

    /// Ab hier rückt die Steuerung enger zusammen.
    private var schmal: Bool { fensterbreite > 0 && fensterbreite < 500 }

    /// Im Fenster liegt iPadOS' Ampel über der oberen linken Ecke — und dort
    /// sitzt der Knopf zum Schließen.
    ///
    /// Der Player muss das selbst berücksichtigen: er ist ein
    /// `fullScreenCover` und hängt nicht unter `HauptView`, dessen
    /// Sicherheitsabstand ihn deshalb nicht erreicht. Genau daran ist die
    /// erste Fassung vorbeigegangen.
    private var imFenster: Bool {
        Fensterknoepfe.imFenster(fensterbreite: fensterbreite)
    }

    init(model: AppModel, item: Item, plan: PlaybackPlan, startAt: Double) {
        self.model = model
        self.startAt = startAt
        // Nicht bei null anfangen: sonst steht der Schieber kurz auf Anfang
        // und springt sichtbar nach vorn, sobald der Strom seine Stelle hat.
        _position = State(initialValue: startAt)
        _item = State(initialValue: item)
        _plan = State(initialValue: plan)
    }

    /// Deckt die Zeit ab, bis VLC das erste Bild ausgibt und der Strom auf
    /// seiner Stelle steht.
    ///
    /// Bewusst schwarz: ein Szenenbild darunter war unruhig, weil es kurz
    /// aufblitzt und sofort wieder weg ist.
    private var startschleier: some View {
        ZStack {
            Color.black
            Lader()
        }
        .ignoresSafeArea()
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    /// Was im großen Bild steht, während nebenan im kleinen Fenster läuft.
    private var kleinerHinweis: some View {
        VStack(spacing: 12) {
            Image(systemName: "pip.fill")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.45))
            Text("Läuft im kleinen Fenster")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.6))
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// Kein Fehler, sondern ein Zwischenstand — deshalb ruhig und ohne
    /// Knopf. Sobald die Leitung steht, verschwindet er von selbst.
    private var verbindungsHinweis: some View {
        VStack(spacing: 10) {
            Lader(groesse: 26, staerke: 2.5)
            Text("Verbindung unterbrochen")
                .font(.subheadline.weight(.medium))
            Text("Läuft weiter, sobald das Netz zurück ist.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: Stil.ecke))
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoSurfaceHost(url: plan.url, startAt: startAt, container: plan.container,
                             pipAvailable: $pipAvailable) {
                surface = $0
                $0.onWiederherstellung = { stelltWiederHer = $0 }
                $0.onPiPStateChanged = { imKleinenFenster = $0 }
                // **Der Knopf folgt VLC, nicht dem Klick und nicht dem Takt.**
                //
                // Am Takt hing er bis zu einer halben Sekunde nach. Im Klick
                // gesetzt ist er zu frueh: das Bild braucht noch seine Zeit,
                // und ein Knopf, der vor dem Bild umspringt, sieht aus wie
                // ein Player, der nicht reagiert. Gemessen auf dem Mac,
                // dreimal: Klick bis VLC „angehalten" meldet 17–25 ms, bis
                // die Filmzeit wirklich steht 26–36 ms.
                //
                // An VLCs eigener Meldung sind Knopf und Bild im selben
                // Moment still. Uebernommen aus der Mac-Fassung (`b5db900`),
                // wo Paul es bestaetigt hat.
                $0.laeuftGemeldet = { laeuft = $0 }
            }
            // Nach der Rückkehr aus Bild-im-Bild meldete die Fläche noch die
            // Größe des kleinen Fensters. Der Stapel richtete sich danach und
            // die ganze Steuerung klebte oben in einem schmalen Streifen.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            // Die Animation der Steuerung lag auf dem ganzen Stapel und hat
            // die Videoflaeche mitgenommen — sie wuchs bei jedem Einblenden
            // sichtbar von klein auf gross.
            .transaction { $0.animation = nil }

            // Solange im kleinen Fenster gespielt wird, ist der Player hier
            // nur noch eine schwarze Fläche — dann darf man auch nichts
            // treffen. Sonst spult man blind im Hintergrund.
            tippflaechen
                .allowsHitTesting(!imKleinenFenster)

            if !bildFrei { startschleier }

            // Unsichtbar; horcht nur auf das Ende der Drehung.
            Drehhorcher {
                if let seit = drehungAngefordert {
                    let ms = Int(Date().timeIntervalSince(seit) * 1000)
                    Protokoll.schreib("[Drehung] fertig nach \(ms) ms")
                }
                drehungFertig = true
            }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            if imKleinenFenster { kleinerHinweis }
            if stelltWiederHer { verbindungsHinweis }

            // Erst wenn das Bild steht — sonst liegt die Steuerung ueber dem
            // Ladeschirm, und das sieht nach zwei Bildschirmen gleichzeitig aus.
            // Nicht zusätzlich zum Wiedergabemenü: sonst scheinen Kopf und
            // Fuß des Players durch und überlagern dessen Kopfzeile.
            // Eigene Ebene, weil sie eine eigene Frage beantwortet — siehe
            // `schleierDa`. Dieselben Kurven wie die Steuerung.
            schleier
                .opacity(schleierDa ? 1 : 0)
                .animation(schleierDa ? .easeOut(duration: 0.18)
                                      : .easeInOut(duration: 0.34),
                           value: schleierDa)

            Group {
                // Eigene Ebene statt zwischen Kopf und Fuss gestapelt: der
                // Fuss ist hoeher als der Kopf, dadurch lag die Mitte
                // zwischen beiden sichtbar ueber der Bildmitte.
                mittelsteuerung
                VStack(spacing: 0) {
                    kopf
                    Spacer(minLength: 0)
                    fuss
                }
                // Oben und unten denselben Abstand zur Bildkante.
                //
                // Vorher lag der Fuß im sicheren Bereich und bekam die rund
                // 21 Punkt des Home-Indikators obendrauf, während oben im
                // Querformat gar nichts freigehalten wird — der Fuß saß also
                // sichtbar höher. Waagerecht bleibt der sichere Bereich
                // dagegen wichtig, dort sitzt die Aussparung.
                .ignoresSafeArea(edges: .vertical)
            }
            // Nicht ein- und aushaengen, sondern nur aufblenden.
            //
            // Vorher lag die Steuerung in einem `if`, wurde also bei jedem
            // Antippen neu aufgebaut und wieder abgeraeumt. Das Auf- und
            // Abbauen kostet einen Bildlauf, und der Uebergang setzte
            // sichtbar hart ein — genau das, was AVPlayerViewController
            // vermeidet: dort bleibt die Steuerung stehen und blendet nur
            // ihre Deckkraft. Aufblenden schnell, Ausblenden gemaechlich;
            // das Erscheinen soll auf den Finger antworten, das Verschwinden
            // darf sich Zeit lassen.
            .opacity(steuerungDa ? 1 : 0)
            .allowsHitTesting(steuerungDa)
            .animation(steuerungDa ? .easeOut(duration: 0.18)
                                   : .easeInOut(duration: 0.34),
                       value: steuerungDa)

            if let sprungAnzeige { sprungRueckmeldung(sprungAnzeige) }
            if wechselt { Lader() }

            // **Nicht ein- und aushaengen, sondern nur aufblenden** — dasselbe
            // Muster wie bei der Steuerung darueber, und aus demselben Grund.
            //
            // Gemessen im Simulator an gerenderten Bildpunkten, Zeiten
            // zehnfach gedehnt, mittlere Leuchtdichte ueber weissem Grund
            // (Ruhewert 0,610):
            //
            //     mit `if` + `.transition`   0,178 → 0,918 → 0,823 → … → 0,610
            //     montiert, aufgeblendet     0,168 → 0,109 → 0,187 → … → 0,610
            //
            // Die `.transition(.opacity)` lief gar nicht: zwischen 0,178 und
            // 0,918 liegt kein Zwischenwert, das Blatt war schlagartig weg.
            //
            // Den Inhalt traegt `PlayerSettingsSheet` nur, solange `offen`
            // gilt. Dauerhaft montiert wuerde er sonst bei jedem Takt
            // `surface?.tonspuren` und `?.untertitelspuren` lesen, und die
            // gehen direkt in VLCKit — rund acht Aufrufe je Sekunde, dauerhaft.
            PlayerSettingsSheet(surface: surface, offen: $zeigeEinstellungen,
                                tempo: $tempo, schlafminuten: $schlafminuten,
                                querformatFest: $querformatFest)
                .opacity(zeigeEinstellungen ? 1 : 0)
                .allowsHitTesting(zeigeEinstellungen)

            // **Ueber allem, weil es alles ersetzt.** Solange der Fernseher
            // dran ist, ist die VLC-Flaeche darunter nur noch Hintergrund;
            // getippt und gesteuert wird hier.
            if let airplayPlan {
                AirPlayFlaeche(
                    url: airplayPlan.url,
                    abSekunden: airplayAb,
                    stand: { stelle, laenge in
                        position = stelle
                        if laenge > 0 { dauer = laenge }
                        meldeFortschritt()
                    },
                    beendet: {
                        if let naechsteFolge { zurNaechstenFolge(naechsteFolge) }
                        else { dismiss() }
                    },
                    fehler: { text in
                        // **Zurueck aufs Geraet, nicht schwarz stehenbleiben.**
                        // Nimmt der Empfaenger den Strom nicht, ist ein
                        // Schwarzbild auf dem Fernseher das Schlechteste von
                        // allem: der Film laeuft nirgends. Also weiter auf dem
                        // Telefon, mit Ansage.
                        hinweis = String(localized: "Der Fernseher nimmt diesen Film nicht an (\(text)). Läuft weiter auf dem iPhone.")
                        airplayUmschalten(false)
                    }
                )
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: airplayPlan?.url)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // Am Stapel gemessen, nicht an der Videofläche: die meldet nach der
        // Rückkehr aus Bild-im-Bild noch die Größe des kleinen Fensters.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { neu in
            fensterbreite = neu
        }
        .onAppear {
            model.fernbefehl = ausfuehren
            // **Auch beim Oeffnen nachsehen, nicht nur beim Wechsel.** Steht
            // das Ziel schon auf dem Fernseher, weil vorher Musik dorthin
            // lief, kommt gar keine Meldung mehr — und der Film waere wieder
            // Ton ohne Bild.
            fernziel.gewechselt = { airplayUmschalten($0) }
            fernziel.nachsehen()
            if fernziel.aufAirPlay { airplayUmschalten(true) }
        }
        .onDisappear {
            model.fernbefehl = nil
            fernziel.aufhoeren()
        }
        .task(id: ausblendMarke) {
            // Im Stehen nichts wegnehmen: wer pausiert hat, schaut gerade
            // nicht aufs Bild, sondern will die Steuerung sehen.
            guard steuerungSichtbar, laeuft else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !amSchieben, !zeigeEinstellungen else { return }
            steuerungSichtbar = false
        }
        .animation(.easeInOut(duration: 0.15), value: sprungAnzeige?.richtung)
        .animation(.easeInOut(duration: 0.18), value: zeigeEinstellungen)

        // Auch die Griffe erneuern: sonst rechnet `umschalten` weiter mit
        // dem Stand von vorhin.
        .onChange(of: laeuft) { _, _ in ausblendMarke += 1; zentraleUebernehmen() }
        .onChange(of: tempo) { _, neu in surface?.tempo = neu }
        .onChange(of: schlafminuten) { _, neu in schlafzeitSetzen(neu) }
        .onChange(of: querformatFest) { _, fest in
            Orientierung.shared.playerGeoeffnet(querformatFest: fest)
        }
        .onChange(of: lebenslage) { _, neu in
            // **Nur messen, nichts richten.** Siehe `geometrieNachmessen`.
            if neu == .active { geometrieNachmessen(anlass: "aktiv") }

            // **Im Hintergrund anhalten — ausser es laeuft anderswo weiter.**
            //
            // Die App erklaert `UIBackgroundModes: audio`; ohne sie gaebe es
            // kein Bild-im-Bild und keinen Sperrbildschirm. Der Preis ist,
            // dass ein weggewischtes Video unbemerkt weiterlaeuft: der
            // Fortschritt zieht davon, und beim Zurueckkommen steht die Folge
            // womoeglich als gesehen da. Swiftfin hatte das zweimal
            // (#871, spaeter als Rueckfall #2175).
            //
            // Die Regel steht in `Hintergrundregel` im Paket, mit Tests und
            // mit den beiden Ausnahmen, um die es dabei geht.
            if neu == .background,
               Hintergrundregel.anhalten(imKleinenFenster: imKleinenFenster,
                                         aufAnderemGeraet: airplayPlan != nil,
                                         laeuft: laeuft) {
                Protokoll.schreib("[Lebenslage] Hintergrund ohne PiP/AirPlay → anhalten")
                surface?.pause()
                laeuft = false
                meldeFortschritt()
            }
        }
        .onChange(of: imKleinenFenster) { _, klein in
            if !klein { geometrieNachmessen(anlass: "aus PiP zurueck") }
        }
        .task { await beobachten() }
        .task {
            naechsteFolge = await model.folgeNach(item)
            abschnitte = await model.abschnitte(fuer: item.id)
            // Erst jetzt steht fest, ob es einen „Weiter"-Knopf geben darf.
            zentraleUebernehmen()
        }
        .onChange(of: dauer) { _, _ in zentraleMelden() }
        .onAppear {
            // **Vor** dem Anfordern fragen: danach steht die Lage schon quer.
            drehungErwartet = Orientierung.drehungErwartet(querformatFest: querformatFest)
            drehungAngefordert = Date()
            Protokoll.schreib("[Drehung] angeordnet · erwartet=\(drehungErwartet)"
                + " · Sperre=\(querformatFest)")
            Orientierung.shared.playerGeoeffnet(querformatFest: querformatFest)
        }
        // **Notausgang.** Bleibt der Uebergang aus — Drehsperre im
        // Kontrollzentrum, abgelehnte Anfrage, ein Fall, den wir nicht kennen —,
        // haengt der Ladeschirm sonst, bis jemand den Player verlaesst. Der
        // Fehler, den er verdeckt, ist eine Sekunde schiefes Bild; der Fehler,
        // den er erzeugen wuerde, waere ein Player, der nie aufmacht.
        //
        // Bewusst **ohne** `guard drehungErwartet`: `.task` und `.onAppear`
        // haben keine zugesicherte Reihenfolge. Laeuft die Aufgabe zuerst,
        // stuende dort noch `false`, der Notausgang stiege sofort aus — und
        // haette genau in dem Fall gefehlt, fuer den er da ist. Ohne erwartete
        // Drehung liest `bildFrei` das Ergebnis ohnehin nicht.
        .task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, !drehungFertig else { return }
            if drehungErwartet {
                Protokoll.schreib("[Dreh] kein Uebergang binnen 1,5 s — Ladeschirm faellt trotzdem")
            }
            drehungFertig = true
        }
        .onDisappear {
            ausblendMarke += 1
            schlafAufgabe?.cancel()
            // Läuft gerade das kleine Fenster, wäre `stop()` genau das, was
            // Bild-im-Bild verhindern soll — und PiP ist der Grund für diese
            // App. Dann bleibt der Strom stehen und wird beendet, wenn das
            // Fenster zugeht.
            if !imKleinenFenster {
                // Die Stelle **vor** dem Anhalten festhalten. Sie stimmt hier
                // zwar noch, weil `position` der Zustand der Ansicht ist und
                // nicht VLCs Zeit — aber das ist eine Zufälligkeit der
                // Reihenfolge, keine Zusage. Nach `stop()` steht VLCs Zeit auf
                // null, und wer die beiden Zeilen einmal tauscht, verliert
                // genau das, worum es bei „Weiterschauen" geht.
                let stelle = position
                surface?.stop()
                zentrale.abgeben()
                Task { await model.reportStopped(item: item, plan: plan, seconds: stelle) }
            }
            Orientierung.shared.playerGeschlossen()
        }
    }

    // MARK: - Schleier

    /// Abdunkeln plus Verlauf oben und unten. Ohne das sind weiße Symbole
    /// über hellen Szenen nicht zu erkennen.
    private var schleier: some View {
        ZStack {
            Color.black.opacity(0.28)
            LinearGradient(colors: [.black.opacity(0.6), .clear],
                           startPoint: .top, endPoint: .center)
            LinearGradient(colors: [.clear, .black.opacity(0.7)],
                           startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // MARK: - Tippflächen

    private var tippflaechen: some View {
        ZStack {
            HStack(spacing: 0) {
                flaeche(richtung: -1)
                flaeche(richtung: 1)
            }

            // Dort, wo der Pause-Knopf sitzt, soll auch dann pausiert werden,
            // wenn er gerade ausgeblendet ist. Wer in die Mitte tippt, meint
            // den Knopf — nicht "zeig mir mal die Steuerung".
            //
            // Liegt bewusst unter der Steuerung: ist die sichtbar, faengt der
            // echte Knopf den Tipp ab. Schmal genug, dass die beiden
            // Spulknoepfe daneben frei bleiben.
            Color.clear
                .frame(width: 108, height: 132)
                .contentShape(Rectangle())
                .onTapGesture { spielenUmschalten() }
        }
        .ignoresSafeArea()
    }

    /// Ein Tipp schaltet die Steuerung, zwei spulen.
    ///
    /// Nicht ueber `onTapGesture(count: 2)` plus `onTapGesture` — dabei muss
    /// der einfache Tipp erst warten, bis der doppelte durchgefallen ist
    /// (`require(toFail:)`), und diese knappe Drittelsekunde ist genau das,
    /// was sich zaeh anfuehlt. Player, die sich flott anfuehlen, warten
    /// nicht: sie schalten beim ersten Tipp sofort und nehmen die Schaltung
    /// zurueck, wenn kurz darauf der zweite kommt. Genau das steht hier.
    private func flaeche(richtung: Int) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { tippen(richtung: richtung) }
    }

    private func tippen(richtung: Int) {
        let jetzt = Date()
        if let vorher = letzterTipp, letzteSeite == richtung,
           jetzt.timeIntervalSince(vorher) < 0.3 {
            letzterTipp = nil
            // Die Schaltung des ersten Tipps zuruecknehmen: ein Doppeltipp
            // spult, er soll die Steuerung nicht nebenbei umlegen.
            steuerungSichtbar.toggle()
            if steuerungSichtbar { ausblendenVerschieben() }
            spulen(Int32(richtung < 0 ? -model.zurueckSekunden : model.vorSekunden))
            return
        }
        letzterTipp = jetzt
        letzteSeite = richtung
        steuerungUmschalten()
    }

    // MARK: - Kopf, Mitte, Fuß

    private var kopf: some View {
        HStack(spacing: 0) {
            knopf("chevron.down", beschriftung: "Player schließen") { dismiss() }
            Spacer(minLength: 0)
            knopf("pip.enter", gedimmt: !pipAvailable, beschriftung: "Bild im Bild") {
                if let grund = surface?.pipUnavailableReason { hinweis = grund }
                else { surface?.startPiP() }
            }
            knopf("slider.horizontal.3", beschriftung: "Wiedergabeeinstellungen") {
                ausblendMarke += 1
                zeigeEinstellungen = true
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 18 + (imFenster ? Fensterknoepfe.hoehe : 0))
    }

    /// Mittig im Bild, nicht am unteren Rand — so ist der Daumen in beiden
    /// Ausrichtungen in der Nähe und die Symbole liegen nicht im Untertitel.
    private var mittelsteuerung: some View {
        HStack(spacing: schmal ? 34 : 52) {
            knopf("gobackward.\(model.zurueckSekunden)", gross: true,
                  takt: taktZurueck,
                  beschriftung: "\(model.zurueckSekunden) Sekunden zurück") {
                spulen(Int32(-model.zurueckSekunden))
            }
            knopf(laeuft ? "pause.fill" : "play.fill", riesig: true,
                  flott: true,
                  beschriftung: laeuft ? "Anhalten" : "Abspielen") { spielenUmschalten() }
            // Vorwärts weiter als rückwärts: vorwärts überspringt man
            // Vorspann und Werbung, rückwärts sucht man einen Satz.
            knopf("goforward.\(model.vorSekunden)", gross: true,
                  takt: taktVor,
                  beschriftung: "\(model.vorSekunden) Sekunden vor") {
                spulen(Int32(model.vorSekunden))
            }
        }
    }

    private var fuss: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Titel unten, nicht oben: dort steht er im Entwurf, und er
            // gehoert zur Zeitleiste, nicht zu den Werkzeugen.
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 19, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let kontext = item.kontextzeile { Text(kontext) }
                        if !plan.isLossless {
                            Label(plan.method.rawValue, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Stil.warnung)
                        }
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
                }

                Spacer(minLength: 0)

                if angebot.sichtbar {
                    Button(action: angebotAusfuehren) {
                        // Serverdaten sind hier nicht im Spiel, aber die
                        // Beschriftung entsteht als `String` im Paket —
                        // deshalb `Text(verbatim:)` statt `Label(_:)`, sonst
                        // würde sie ein zweites Mal nachgeschlagen.
                        HStack(spacing: 6) {
                            Image(systemName: angebot.zeichen)
                            Text(verbatim: angebot.beschriftung)
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 15)
                        .frame(height: 34)
                        .background(.white.opacity(0.16), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.24)))
                    }
                    .foregroundStyle(.white)
                    .fixedSize()
                    .transition(.opacity)
                }
            }
            .foregroundStyle(.white)

            HStack(spacing: 12) {
                Text(zeit(position))
                Zeitregler(wert: $position, bis: max(dauer, 1)) { schiebt in
                    if schiebt {
                        amSchieben = true
                        zuletztGeschoben = Date()
                        ausblendMarke += 1
                    } else {
                        // Ausdrücklich zurücksetzen: sonst bliebe amSchieben
                        // stehen und die Zeitanzeige würde nie mehr
                        // nachgeführt.
                        amSchieben = false
                        surface?.seek(toSeconds: position)
                        sprungBis = Date().addingTimeInterval(Zeitannahme.sprungriegel)
                        meldeFortschritt()
                        ausblendenVerschieben()
                    }
                }
                Text("−" + zeit(max(dauer - position, 0)))
            }
            .font(.system(size: 13).monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))

            if let hinweis {
                Text(hinweis)
                    .font(.caption2).foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .task {
                        try? await Task.sleep(for: .seconds(5))
                        self.hinweis = nil
                    }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

    private func knopf(_ symbol: String, gross: Bool = false, riesig: Bool = false,
                       gedimmt: Bool = false, takt: Int = 0, flott: Bool = false,
                       beschriftung: LocalizedStringKey? = nil,
                       aktion: @escaping () -> Void) -> some View {
        Button(action: aktion) {
            Image(systemName: symbol)
                // Ohne das blendet SwiftUI die beiden Symbole ineinander —
                // das sah nach Fehler aus, nicht nach Absicht.
                //
                // `.downUp` schiebt beide Symbole aneinander vorbei und
                // braucht dafuer sichtbar Zeit. Fuer Pause ist das zu lang:
                // der Knopf muss im selben Moment umspringen, in dem der Ton
                // aufhoert, sonst wirkt der ganze Player traege. Dort also
                // der einfache Austausch.
                .contentTransition(.symbolEffect(flott ? .replace.offUp
                                                       : .replace.downUp))
                .font(.system(size: riesig ? (schmal ? 36 : 48)
                                          : (gross ? (schmal ? 24 : 30) : 17),
                              weight: .medium))
                .foregroundStyle(.white.opacity(gedimmt ? 0.35 : 1))
                // Diskreter Effekt aus SF Symbols: spielt einmal ab und geht
                // von selbst in die Ruhelage zurueck. Ein selbst gerechneter
                // Winkel blieb dagegen stehen.
                .symbolEffect(.bounce, options: .speed(1.7), value: takt)
                .frame(width: kante(riesig), height: kante(riesig))
                .contentShape(Rectangle())
        }
        .accessibilityLabel(beschriftung.map { Text($0) } ?? Text(verbatim: symbol))
        .accessibilityRemoveTraits(gedimmt ? .isButton : [])
    }

    /// Kantenlänge der runden Knöpfe. Schmal eine Stufe kleiner, sonst
    /// stossen Zurück und Vor in einem 320er Fenster aneinander.
    private func kante(_ riesig: Bool) -> CGFloat {
        if riesig { return schmal ? 60 : 78 }
        return schmal ? 40 : 46
    }

    private func sprungRueckmeldung(_ anzeige: (richtung: Int, sekunden: Int)) -> some View {
        HStack(spacing: 0) {
            if anzeige.richtung > 0 { Spacer() }
            Sprungmarke(richtung: anzeige.richtung, sekunden: anzeige.sekunden)
                // Ohne eigene Kennung baut SwiftUI die Ansicht bei zwei
                // Spruengen hintereinander nicht neu — die Drehung bliebe aus.
                .id(anzeige.richtung < 0 ? -taktZurueck : taktVor)
            if anzeige.richtung < 0 { Spacer() }
        }
        .padding(.horizontal, 44)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// Welcher Knopf gerade gilt — überspringen, weiterschalten oder keiner.
    ///
    /// **Es ist derselbe Knopf.** Gestaltung und Platz bleiben; nur
    /// Beschriftung, Zeichen und Zeitpunkt wechseln. Die Regel dahinter steht
    /// im Paket, damit sie auf allen vier Plattformen dieselbe ist.
    private var angebot: Knopfangebot {
        guard !wechselt else { return .keiner }
        return Abschnittslogik.angebot(position: position, dauer: dauer,
                                       abschnitte: abschnitte,
                                       hatNaechsteFolge: naechsteFolge != nil)
    }

    /// Der Druck darauf.
    private func angebotAusfuehren() {
        switch angebot {
        case .keiner:
            break
        case let .ueberspringen(nach, _):
            // Wie ein Sprung von Hand: Stelle setzen, springen, und die
            // Anzeige kurz nicht überschreiben lassen.
            position = nach
            surface?.seek(toSeconds: nach)
            sprungBis = Date().addingTimeInterval(Zeitannahme.sprungriegel)
            meldeFortschritt()
            ausblendenVerschieben()
        case .naechsteFolge:
            if let naechsteFolge { zurNaechstenFolge(naechsteFolge) }
        }
    }

    // MARK: - Aktionen

    /// Befehle aus dem Jellyfin-Dashboard.
    private func ausfuehren(_ befehl: Fernbefehl) {
        switch befehl {
        case .pause:
            surface?.pause()
            withAnimation(Stil.umschalten) { laeuft = false }
        case .weiter:
            surface?.resume()
            withAnimation(Stil.umschalten) { laeuft = true }
        case .umschalten:
            if laeuft { surface?.pause() } else { surface?.resume() }
            withAnimation(Stil.umschalten) { laeuft.toggle() }
        case .stopp:
            surface?.stop()
            dismiss()
        case let .springenAuf(sekunden):
            position = sekunden
            surface?.seek(toSeconds: sekunden)
            sprungBis = Date().addingTimeInterval(Zeitannahme.sprungriegel)
        case .vor:
            spulen(Int32(model.vorSekunden))
        case .zurueck:
            spulen(Int32(-model.zurueckSekunden))
        case .naechste:
            if let naechsteFolge { zurNaechstenFolge(naechsteFolge) }
        case .vorige:
            break
        }
        steuerungSichtbar = true
        ausblendenVerschieben()
    }

    /// Anhalten und Weiterlaufen — von der Mitte des Bildes wie vom Knopf.
    /// Zustand setzen und alles nachziehen, was daran hängt.
    ///
    /// `spielenUmschalten` kehrt um; das ist richtig für den Knopf im Bild,
    /// aber falsch für einen Befehl von außen, der ausdrücklich „spiel ab"
    /// oder „halt an" sagt.
    private func laufzustand(_ an: Bool) {
        withAnimation(.easeOut(duration: 0.12)) { laeuft = an }
        steuerungSichtbar = true
        zentrale.standNachziehen(position: position, laeuft: an, tempo: tempo)
        ausblendenVerschieben()
        meldeFortschritt()
    }

    private func spielenUmschalten() {
        // Kein `laeuft.toggle()` mehr: der Knopf wartet auf VLCs Meldung.
        // Siehe `laeuftGemeldet` oben.
        if laeuft { surface?.pause() } else { surface?.resume() }
        steuerungSichtbar = true
        zentrale.standNachziehen(position: position, laeuft: laeuft, tempo: tempo)
        ausblendenVerschieben()
        meldeFortschritt()
    }

    private func spulen(_ sekunden: Int32) {
        surface?.jump(seconds: sekunden)
        sprungBis = Date().addingTimeInterval(Zeitannahme.sprungriegel)
        if sekunden < 0 { taktZurueck += 1 } else { taktVor += 1 }
        sprungAnzeige = (sekunden < 0 ? -1 : 1, Int(abs(sekunden)))
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            sprungAnzeige = nil
        }
        if steuerungSichtbar { ausblendenVerschieben() }
        meldeFortschritt()
    }

    /// Wechselt im laufenden Player zur nächsten Folge, statt zurück in die
    /// Übersicht zu springen.
    private func zurNaechstenFolge(_ folge: Item) {
        wechselt = true
        Task {
            await model.reportStopped(item: item, plan: plan, seconds: position)
            guard let neuerPlan = await model.plan(for: folge.id) else {
                hinweis = String(localized: "Nächste Folge konnte nicht geladen werden.")
                wechselt = false
                return
            }
            item = folge
            plan = neuerPlan
            position = 0
            // Eine neue Folge fängt eine eigene Zeitrechnung an. Bliebe die
            // alte stehen, wären Notbremse und Frischefenster für den neuen
            // Titel sofort abgelaufen — auf dem Fernseher hat genau das eine
            // Folge übersprungen.
            seitStart = Date()
            // Den Ladeschirm zurückholen. Sonst übernimmt die Schleife im
            // nächsten Takt noch die Zeit der **alten** Folge — ein Vorwärts-
            // sprung, den `Zeitannahme` nicht sperrt, weil nur Rücksprünge
            // gesperrt sind. Der Balken zuckte ans Ende, und beim
            // selbsttätigen Weiterschalten löste es gleich noch einmal aus.
            erstesBildDa = false
            spurenGesetzt = false
            titelwechsel += 1
            surface?.play(url: neuerPlan.url, abSekunden: 0, container: neuerPlan.container)
            // Hier gemeldet, nicht von der Schleife: Titel und Plan sind in
            // diesem Augenblick bekannt, die Stelle ist null. Der Stand muss
            // es erfahren, sonst meldet die Schleife gleich noch einmal.
            await model.reportStart(item: folge, plan: neuerPlan, seconds: 0)
            startGemeldet = true
            naechsteFolge = await model.folgeNach(folge)
            // **Die neue Folge hat eigene Abschnitte.** Ohne das trüge sie
            // die des Vorgängers, und der Knopf erschiene an dessen Stellen.
            abschnitte = await model.abschnitte(fuer: folge.id)
            zentraleUebernehmen()
            wechselt = false
            steuerungSichtbar = true
            ausblendenVerschieben()
        }
    }

    // MARK: - Auf den Fernseher und zurueck

    /// Das Ziel hat gewechselt — also wechselt der Abspieler mit.
    ///
    /// **Zwei Abspieler, eine Stelle.** VLC gibt an `AVPlayer` ab und
    /// umgekehrt; weitergegeben wird `position`, der Zustand der Ansicht.
    /// Nicht VLCs Zeit: die steht nach dem Anhalten nicht mehr verlaesslich,
    /// und genau daran ist das Fortsetzen schon einmal gescheitert.
    ///
    /// **Geht es nicht, sagt es das.** Der Ton laeuft dann trotzdem auf dem
    /// Fernseher — nur ohne Bild, weil der Empfaenger den Strom ablehnt. Ohne
    /// Meldung sieht das nach einem Fehler in Swiftly aus, und es ist keiner.
    private func airplayUmschalten(_ an: Bool) {
        if an {
            guard airplayPlan == nil else { return }
            guard let client = model.client, let quelle = plan.quelle else { return }
            Task {
                do {
                    switch try await client.airplayPlan(for: item.id, quelle: quelle) {
                    case .gehtNicht(let eignung):
                        hinweis = eignung.meldung
                        Protokoll.schreib("[AirPlay] abgelehnt — "
                            + eignung.hindernisse.map(\.codec).joined(separator: ", "))
                    case .geht(let neu):
                        // **Die Gruende mit ins Protokoll.** Ohne sie stand
                        // dort nur „Transcode", und das sagt nicht, woran
                        // der Server sich stoert — genau die Angabe, die beim
                        // ersten Schwarzbild gefehlt hat.
                        let gruende = neu.reasons.isEmpty
                            ? "keine" : neu.reasons.map(\.codec).joined(separator: ",")
                        Protokoll.schreib("[AirPlay] uebernimmt ab \(Int(position)) s"
                            + " — \(neu.method.wireName), Gruende: \(gruende)"
                            + " — \(neu.url.absoluteString.prefix(160))")
                        airplayAb = position
                        surface?.pause()
                        // Der Sperrbildschirm haengt an VLCs Griffen; die
                        // zeigen jetzt ins Leere. `AVPlayer` bringt seine
                        // eigene Anzeige mit.
                        zentrale.abgeben()
                        airplayPlan = neu
                    }
                } catch {
                    hinweis = error.localizedDescription
                }
            }
        } else {
            guard airplayPlan != nil else { return }
            let stelle = position
            Protokoll.schreib("[AirPlay] zurueck aufs Geraet bei \(Int(stelle)) s")
            airplayPlan = nil
            surface?.seek(toSeconds: stelle)
            surface?.resume()
            zentraleUebernehmen()
        }
    }

    private func schlafzeitSetzen(_ minuten: Int?) {
        schlafAufgabe?.cancel()
        guard let minuten else { return }
        schlafAufgabe = Task {
            try? await Task.sleep(for: .seconds(minuten * 60))
            guard !Task.isCancelled else { return }
            surface?.pause()
            laeuft = false
            steuerungSichtbar = true
            hinweis = String(localized: "Schlafzeit abgelaufen.")
        }
    }

    private func steuerungUmschalten() {
        steuerungSichtbar.toggle()
        if steuerungSichtbar { ausblendenVerschieben() } else { ausblendMarke += 1 }
    }

    /// Startet die Ausblendfrist neu.
    ///
    /// Nur eine Marke hochzaehlen — die Frist selbst haengt an `.task(id:)`.
    /// Die frühere Fassung hielt die Aufgabe selbst und ist mehrfach
    /// hängengeblieben; dann stand die Steuerung dauerhaft im Bild.
    private func ausblendenVerschieben() { ausblendMarke += 1 }

    private func beobachten() async {
        VLCPlayerView.log.info("Player geöffnet, Startposition \(Int(startAt)) s")
        zentraleUebernehmen()
        ausblendenVerschieben()

        // Die Regeln stehen in `Wiedergabetakt`, geteilt mit den anderen
        // Plattformen. Hier bleibt, was nur das iPhone tut: die Steuerung
        // ausblenden, den Sperrbildschirm nachziehen, den hängenden Regler
        // auffangen.
        var stand = Wiedergabetakt.Stand()
        var letzterWechsel = titelwechsel
        var takte = 0

        while !Task.isCancelled {
            try? await Task.sleep(for: Wiedergabetakt.taktlaenge)
            guard let surface else { continue }

            // Sicherung: bleibt das Schieben trotzdem hängen, nach drei
            // Sekunden ohne Bewegung selbst zurücksetzen.
            if amSchieben, let zuletzt = zuletztGeschoben,
               Date().timeIntervalSince(zuletzt) > 3 {
                amSchieben = false
            }

            // Den Stand der Ansicht übernehmen: sie ändert `position`, während
            // der Finger am Regler liegt.
            stand.position = position
            stand.dauer = dauer
            stand.laeuft = laeuft
            stand.erstesBildDa = erstesBildDa
            stand.spurenGesetzt = spurenGesetzt
            stand.startGemeldet = startGemeldet

            // Ein Titelwechsel ist angesagt: Stand zuruecksetzen, und zwar
            // ueber die geteilte Regel. `seitMeldung` lebt nur hier und haette
            // den Wechsel sonst ueberlebt — die erste Meldung der neuen Folge
            // waere sofort gekommen statt nach zehn Sekunden.
            if titelwechsel != letzterWechsel {
                letzterWechsel = titelwechsel
                // `true`, weil der Wechsel den Start selbst gemeldet hat.
                Wiedergabetakt.neuerTitel(&stand, startGemeldet: true)
            }

            // **Angekommen heisst angekommen — nicht „zwei Sekunden sind um".**
            //
            // Der Riegel nach einem Sprung stand auf einer festen Frist. Ist
            // VLC frueher da, bleibt die Zeit trotzdem stehen; braucht es
            // laenger, faellt der Riegel zu frueh und die Anzeige springt auf
            // die alte Stelle zurueck. Gemessen wird deshalb, ob VLC dort
            // ist, wo wir hinwollten — die Frist ist nur noch der Deckel fuer
            // den Fall, dass ein Sprung gar nicht ankommt.
            //
            // Von tvOS uebernommen, wo es seit Langem so laeuft. Die
            // tvOS-Sitzung hat den Unterschied im Tiefendurchgang gefunden:
            // die drei Plattformen hatten nicht verschiedene Zahlen, sondern
            // verschiedene Verfahren.
            if sprungBis != nil, abs(surface.positionSeconds - position) < Zeitannahme.sprungAngekommen {
                sprungBis = nil
            }

            let auftrag = Wiedergabetakt.rechnen(
                &stand,
                messung: .init(dauer: surface.durationSeconds,
                               position: surface.positionSeconds,
                               guteStelle: surface.guteStelle,
                               zeigtBild: surface.zeigtBild,
                               stelltEin: surface.stelltEin,
                               laeuft: surface.isPlaying,
                               hatTonspuren: !surface.tonspuren.isEmpty),
                stelltWiederHer: stelltWiederHer,
                sprungLaeuft: sprungBis.map { Date() < $0 } ?? false,
                amSchieben: amSchieben,
                seitStart: seitStart)

            position = stand.position
            dauer = stand.dauer
            laeuft = stand.laeuft
            spurenGesetzt = stand.spurenGesetzt
            startGemeldet = stand.startGemeldet

            if auftrag.ladeschirmWeg {
                withAnimation(.easeOut(duration: 0.3)) { erstesBildDa = true }
                ausblendenVerschieben()
            }
            if auftrag.spurenAnwenden {
                surface.wendeSprachenAn(ton: model.tonSprache,
                                        untertitel: model.untertitelSprache,
                                        automatisch: model.untertitelAutomatisch)
            }
            if auftrag.spurenAnwenden { surface.kanaeleNachmessen() }
            // Waehrend des Wechsels schweigen. Sonst geht ein Fortschritt
            // fuer den **alten** Titel hinaus, nachdem sein Ende schon
            // gemeldet wurde — die Reihenfolge, die C4 zusagt, waere gebrochen.
            if auftrag.startMelden, !wechselt {
                // Die tatsaechliche Stelle, nicht das Ziel: seit der Start erst
                // gemeldet wird, wenn ein Bild steht, liegt das Einsteuern
                // dazwischen. Bei grossen Dateien sind das bis zu 25 Sekunden.
                await model.reportStart(item: item, plan: plan, seconds: stand.position)
            }
            if auftrag.fortschrittMelden, !wechselt {
                meldeFortschritt()
                #if DEBUG
                print("[App] Position \(Int(position)) s · Dauer \(Int(dauer)) s · läuft \(laeuft) · schiebt \(amSchieben)")
                #endif
            }

            // Am Ende von selbst weiter, wenn gewünscht.
            if model.naechsteAutomatisch, let folge = naechsteFolge, !wechselt,
               Folgenende.weiterschalten(position: position, dauer: dauer,
                                         seitOeffnen: Date().timeIntervalSince(seitStart)) {
                zurNaechstenFolge(folge)
            }

            takte += 1
            // Der Sperrbildschirm braucht die Stelle nur im Sekundentakt.
            if takte % 2 == 0 {
                zentrale.standNachziehen(position: position, laeuft: laeuft, tempo: tempo)
            }
        }
    }

    /// Meldet dem System, was läuft, und nimmt seine Befehle entgegen.
    private func zentraleUebernehmen() {
        zentrale.uebernehmen(.init(
            // **Befehlen, nicht fragen.** Diese Abschlüsse werden einmal
            // eingetragen und halten die Ansicht so fest, wie sie in diesem
            // Augenblick war — SwiftUI-Ansichten sind Werte. `laeuft` darin
            // sagte nicht, was gerade läuft, sondern was beim Öffnen lief,
            // und das ist immer `true`. Also hielt „anhalten" jedesmal an,
            // und „abspielen" tat nie etwas.
            //
            // Unsichtbar blieb es, weil **Schreiben** funktioniert: `@State`
            // legt seine Werte außerhalb der Struktur ab. Nur Lesen liefert
            // den alten Stand. Der tvOS-Chat hat es dort gefunden, wo die
            // Zentrale der einzige Weg ist; am Telefon greift sie nur vom
            // Sperrbildschirm, aus dem Kontrollzentrum und über den
            // Kopfhörerknopf — und dort hatte es niemand nach dem Pausieren
            // versucht.
            abspielen:   { surface?.resume(); laufzustand(true) },
            anhalten:    { surface?.pause();  laufzustand(false) },
            umschalten:  { spielenUmschalten() },
            springenAuf: { ziel in surface?.seek(toSeconds: ziel); position = ziel },
            vor:         { spulen(Int32(model.vorSekunden)) },
            zurueck:     { spulen(Int32(-model.zurueckSekunden)) },
            naechste:    naechsteFolge.map { folge in { zurNaechstenFolge(folge) } }))
        zentraleMelden()
    }

    private func zentraleMelden() {
        zentrale.melden(item: item, position: position, dauer: dauer, tempo: tempo,
                        laeuft: laeuft,
                        sprungweite: (model.zurueckSekunden, model.vorSekunden),
                        bildURL: model.sperrbildURL(for: item))
    }

    private func meldeFortschritt() {
        Task {
            await model.reportProgress(item: item, plan: plan,
                                       seconds: position, paused: !laeuft)
        }
    }

    private func zeit(_ sekunden: Double) -> String { Spielzeit.text(sekunden) }

    /// **Messung, kein Eingriff.**
    ///
    /// Paul: nach `PiP starten → Kontrollzentrum auf → zu → im PiP-Fenster auf
    /// Vollbild` ist die ganze Oberflaeche rund zwei Sekunden lang zu gross,
    /// nur die Haelfte ist zu sehen, dann springt sie zurueck.
    ///
    /// Zwei Erklaerungen kommen in Frage, und sie sind am Protokoll zu
    /// **unterscheiden** — genau dafuer steht das hier:
    ///
    /// - **Drehmaske.** `Orientierung` wird nur in `onAppear`, `onDisappear`
    ///   und bei geaenderter Querformatsperre gerufen; nichts setzt sie neu,
    ///   wenn die App aus dem Hintergrund zurueckkommt, und das
    ///   Kontrollzentrum schickt sie dorthin. Dann stuende `erlaubt` auf
    ///   `.portrait`, waehrend die Szene quer liegt.
    /// - **Geometrie.** Die Szene meldet noch die Groesse des kleinen
    ///   Fensters. Das ist der Zwilling eines schon behobenen Fehlers — damals
    ///   traf es die Videoflaeche, hier waere es eine Ebene hoeher. Dann
    ///   wiche `fensterbreite` von der Fensterbreite der Szene ab.
    ///
    /// Ein einzelner Wert beim Umschalten reicht nicht: der Fehler dauert
    /// zwei Sekunden, der Augenblick des Wechsels liegt davor. Also drei
    /// Sekunden lang alle 250 ms.
    private func geometrieNachmessen(anlass: String) {
        Task { @MainActor in
            for schritt in 0..<12 {
                let szene = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }.first
                let fenster = szene?.keyWindow?.bounds.size ?? .zero
                let lage = szene?.interfaceOrientation.rawValue ?? -1
                let maske = Orientierung.shared.erlaubt.rawValue
                Protokoll.schreib("[Geometrie] \(anlass) +\(schritt * 250) ms"
                    + " · Fenster \(Int(fenster.width))x\(Int(fenster.height))"
                    + " · Ansicht \(Int(fensterbreite))"
                    + " · Lage \(lage) · Maske \(maske)"
                    + " · PiP \(imKleinenFenster)")
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

/// Rueckmeldung beim Doppeltipp — dieselbe Drehung wie auf den Knoepfen,
/// damit Knopf und Doppeltipp nicht wie zwei verschiedene Dinge wirken.
private struct Sprungmarke: View {
    let richtung: Int
    let sekunden: Int
    @State private var gedreht = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: richtung < 0 ? "gobackward" : "goforward")
                .font(.system(size: 32, weight: .medium))
                .symbolEffect(.bounce, options: .speed(1.7), value: gedreht)
            Text("\(sekunden) s").font(.footnote.weight(.medium))
        }
        .foregroundStyle(.white)
        .frame(width: 108, height: 108)
        .background(.black.opacity(0.45), in: Circle())
        .onAppear { gedreht = true }
    }
}

struct VideoSurfaceHost: UIViewRepresentable {
    let url: URL
    let startAt: Double
    let container: String?
    @Binding var pipAvailable: Bool
    let onCreate: (VLCPlayerView) -> Void

    func makeUIView(context: Context) -> VLCPlayerView {
        let view = VLCPlayerView()
        view.onPiPAvailable = { pipAvailable = $0 }
        view.play(url: url, abSekunden: startAt, container: container)
        DispatchQueue.main.async { onCreate(view) }
        return view
    }

    func updateUIView(_ view: VLCPlayerView, context: Context) {}

    /// Ohne das laeuft der Wachhund-Timer der abgeraeumten View endlos
    /// weiter — im Geraeteprotokoll als Takt mit 'spielt false' zu sehen.
    /// Auf stop() im onDisappear ist kein Verlass: das trifft die View, auf
    /// die 'surface' zeigt, nicht zwingend jede, die SwiftUI angelegt hat.
    static func dismantleUIView(_ view: VLCPlayerView, coordinator: ()) {
        MainActor.assumeIsolated { view.stop() }
    }
}
