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
    /// Zaehlt nur, solange das Schild an ist — siehe `Technikschild`.
    @AppStorage("technikschild") private var technikschild = false
    @State private var spielwerte: Spielwerte?
    /// Zaehlt mit, wie oft CoreAnimation uns tatsaechlich ruft -- laeuft
    /// nur, solange das Schild an ist.
    @State private var schirmtakt = Schirmtakt()
    /// Formatfuellend statt ganzes Bild. Bleibt ueber Folgen hinweg stehen --
    /// wer einmal die Balken weghaben will, will das meist auch danach.
    @AppStorage("bildfuellend") private var bildfuellend = false
    /// Verhindert, dass eine einzige Zieh-Geste mehrfach umschaltet.
    @State private var zoomSchonGeschaltet = false

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

    /// **Der Angebotsknopf unten rechts** — eine Regel, egal ob die Steuerung
    /// offen ist (Paul, 17.09.2026): Überspringen steht, solange der Abschnitt
    /// läuft; die Karte „Nächste Folge" steht bei geschlossener Steuerung
    /// (`Angebotsebene.anzeige`), bei offener steht dort der normale Knopf.
    private var angebotDa: Bool {
        guard angebot.sichtbar, bildFrei, !zeigeEinstellungen, !imKleinenFenster,
              airplayPlan == nil, !wechselt else { return false }
        return ebene.anzeige.sichtbar || (steuerungDa && angebot == .naechsteFolge)
    }

    private var countdownAnteil: Double? {
        if case let .karte(anteil) = ebene.anzeige { return anteil }
        return nil
    }

    /// **Die Abdunklung bleibt unter dem Wiedergabemenue stehen.**
    ///
    /// Sie hing frueher mit an `!zeigeEinstellungen`, war unter dem Blatt also
    /// gar nicht da — und musste beim Schliessen erst wieder hochfahren. In
    /// dem Fenster sah man ungedaempftes Video, heller als vorher *und*
    /// nachher.
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
    /// Filmanfang sie kaschiert.
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
    /// Ein Sprung, bei dem VLC noch nicht angekommen ist — bis dahin zeigt die
    /// Zeitleiste das Ziel. Die Regel steht in `Wiedergabetakt.Sprung`.
    @State private var sprung: Wiedergabetakt.Sprung?
    /// Der erste Tipp eines möglichen Doppeltipps schaltet erst, wenn kein
    /// zweiter kommt — siehe `tippen(richtung:)`.
    @State private var tippAufgabe: Task<Void, Never>?
    /// Die Füllung der Karte als durchgehende Bewegung (`Fuellungsuhr`).
    @State private var fuellungsuhr = Fuellungsuhr()
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
    /// „Intro überspringen" und „Nächste Folge" über dem Bild, ohne dass die
    /// Steuerung aufgehen muss. Was wann gilt, steht in `Angebotsebene`.
    @State private var ebene = Angebotsebene()
    /// Spiegelt den Riegel von `folgenwechsel` für die Ansicht.
    @State private var wechselt = false
    @State private var folgenwechsel = Folgenwechsel()
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
        ZStack(alignment: .top) {
            ZStack {
                Color.black
                Lader()
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // **Schließen geht auch, bevor das Bild da ist.** Die Steuerung
            // erscheint erst mit dem ersten Bild; bis dahin lag hier nur der
            // Schleier, und wer es sich anders überlegte, musste warten, bis
            // der Strom stand. Von einem Tester gemeldet.
            //
            // Derselbe Knopf an derselben Stelle wie im Kopf der Steuerung —
            // gleicher Rand, gleicher Abstand oben, waagerecht im sicheren
            // Bereich. Sobald sie erscheint, liegt ihrer genau darüber.
            // **Erst, wenn die Lage steht.** Die Drehung ins Querformat läuft
            // beim Öffnen noch; davor lag der Knopf oben links im
            // Hochformat — bei der Uhr — und sprang dann an seinen Platz.
            // Jetzt blendet er dort ein, wo er bleibt.
            if !drehungErwartet || drehungFertig {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        knopf("chevron.down", beschriftung: "Player schließen") { dismiss() }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 18 + (imFenster ? Fensterknoepfe.hoehe : 0))
                    Spacer(minLength: 0)
                }
                .ignoresSafeArea(edges: .vertical)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: drehungFertig)
        .transition(.opacity)
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
                             puffer: model.pufferstufe,
                             untertitel: model.untertiteldateien(plan),
                             pipAvailable: $pipAvailable) {
                surface = $0
                $0.onWiederherstellung = { stelltWiederHer = $0 }
                $0.onPiPStateChanged = { imKleinenFenster = $0 }
                // **Der Knopf folgt VLC, nicht dem Klick und nicht dem Takt.**
                //
                // Am Takt hing er bis zu einer halben Sekunde nach. Im Klick
                // gesetzt ist er zu frueh: das Bild braucht noch seine Zeit,
                // und ein Knopf, der vor dem Bild umspringt, sieht aus wie ein
                // Player, der nicht reagiert. Gemessen auf dem Mac, dreimal:
                // Klick bis VLC „angehalten" meldet 17–25 ms, bis die Filmzeit
                // wirklich steht 26–36 ms.
                //
                // An VLCs eigener Meldung sind Knopf und Bild im selben Moment
                // still. Uebernommen aus der Mac-Fassung (`b5db900`), wo
                // Dem Server im selben Moment (T1-N1) — `model` hier
                // festgehalten, der Rueckruf lebt laenger als diese Ansicht.
                let melder = model
                $0.laeuftGemeldet = { [weak flaeche = $0] an in
                    laeuft = an
                    melder.laufzustandGemeldet(laeuft: an, sekunden: flaeche?.positionSeconds ?? 0)
                }
                $0.sprungGemeldet = { ziel in melder.sprungGemeldet(ziel: ziel) }
                $0.spurenGemeldet = { spuren in melder.spurenGewaehlt(spuren) }
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
                .animation(schleierDa ? .snappy(duration: 0.18, extraBounce: 0)
                                      : .smooth(duration: 0.34),
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
            // **Federn, damit ein zweiter Tipp nicht warten muss.** Die
            // Asymmetrie bleibt — schnell auf, gemaechlich zu —, aber eine
            // feste Dauer laesst sich nicht umlenken: wer zweimal kurz
            // hintereinander tippt, sah die Blende von vorn beginnen.
            .animation(steuerungDa ? .snappy(duration: 0.18, extraBounce: 0)
                                   : .smooth(duration: 0.34),
                       value: steuerungDa)

            // **Die Einblendung — und derselbe Knopf bei offener Steuerung.**
            // Ein Tipp darauf führt aus; ein Tipp daneben öffnet wie immer die
            // Steuerung. Beide stehen an genau dieser einen Stelle (Paul,
            // 17.09.2026): vorher lag der Knopf bei offener Steuerung in der
            // Titelzeile, zehn Punkt höher, und sprang beim Aufblenden. Der Fuß
            // hält ihm dafür nur den Platz frei. Öffnen und Schließen der
            // Steuerung lassen ihn stehen; er kommt und geht mit denselben
            // Kurven wie die Steuerung.
            if angebotDa {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Angebotsknopf(angebot: angebot,
                                      fuellung: countdownAnteil == nil ? nil : fuellungsuhr,
                                      rest: ebene.countdownRest,
                                      aktion: angebotAusfuehren)
                            // VoiceOver: Wischen mit zwei Fingern (Z) sagt ab.
                            .accessibilityAction(.escape) { _ = ebene.schliessen() }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18 + 44)
                .ignoresSafeArea(edges: .vertical)
                .transition(.asymmetric(
                    insertion: .opacity.animation(.snappy(duration: 0.18, extraBounce: 0)),
                    removal: .opacity.animation(.smooth(duration: 0.34))))
            }

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
            PlayerSettingsSheet(surface: surface, plan: plan, offen: $zeigeEinstellungen,
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
        // **Das Technikschild.** Es liegt ueber allem und nimmt nichts an:
        // eine Auskunft, kein Bedienteil. Angeschaltet wird es in den
        // Wiedergabe-Einstellungen; wer es nicht sucht, sieht es nie.
        .overlay(alignment: .topLeading) {
            if technikschild {
                Technikschild(plan: plan, werte: spielwerte, flaeche: surface,
                              schirmHertz: schirmtakt.hertz)
                    .padding(.leading, Stil.randAbstand)
                    .padding(.top, 12)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(Stil.einblenden, value: technikschild)
        // Zwei Sekunden sind schnell genug, um einem Ruckler zuzusehen, und
        // langsam genug, dass die Zahlen lesbar stehenbleiben.
        .task(id: technikschild) {
            guard technikschild else { schirmtakt.anhalten(); return }
            // Nur mitzaehlen, solange jemand hinsieht: ein vergessener
            // Zaehler auf dem Hauptlauf waere selbst die Last, die er messen
            // soll.
            schirmtakt.starten()
            defer { schirmtakt.anhalten() }
            while !Task.isCancelled {
                // Die Rate entsteht aus der Differenz zum letzten Mal —
                // siehe `Spielwerte`.
                spielwerte = Spielwerte(surface?.statistik, stelle: surface?.positionSeconds ?? 0,
                                        laeuft: surface?.isPlaying ?? false, vorher: spielwerte)
                try? await Task.sleep(for: .seconds(2))
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
        // Pause hält auch die Füllung der Karte sofort an, nicht erst im Takt.
        .onChange(of: laeuft) { _, _ in ausblendMarke += 1; zentraleUebernehmen(); fuellungStellen() }
        // **Nach dem Schliessen faengt die Uhr von vorn an.**
        //
        // Der Riegel oben (`!zeigeEinstellungen`) haelt die Steuerung
        // richtigerweise offen, solange die Tafel steht -- aber er sitzt
        // *nach* dem Schlafen. Die Aufgabe endet damit, ohne etwas
        // wegzunehmen, und ohne neue Marke laeuft keine zweite an: die
        // Steuerung waere nach dem Schliessen dauerhaft stehen geblieben.
        .onChange(of: zeigeEinstellungen) { _, offen in if !offen { ausblendMarke += 1 } }
        // Die Einblendung hört auf die gewollte Steuerung, nicht auf die
        // sichtbare: beim Öffnen steht sie schon auf „an", bevor das Bild da
        // ist, und ihr erstes Ausblenden ist kein Blick in die Steuerung, der
        // „Rückblick überspringen" wegschicken dürfte.
        .onChange(of: steuerungSichtbar, initial: true) { _, offen in
            ebene.steuerung(offen: offen)
            fuellungStellen()
        }
        .onChange(of: tempo) { _, neu in surface?.tempo = neu }
        .onChange(of: schlafminuten) { _, neu in schlafzeitSetzen(neu) }
        .onChange(of: querformatFest) { _, fest in
            Orientierung.shared.playerGeoeffnet(querformatFest: fest)
        }
        // **Zusammen- und Auseinanderziehen wechselt das Bildformat.**
        //
        // Zwei Zustaende, wie bei Netflix und Apples eigener Videoapp: das
        // ganze Bild mit Balken, oder formatfuellend mit Beschnitt. Ein
        // dritter waere nur eine Streckung, und die will niemand.
        //
        // **Ohne Beschriftung.** Hier stand ein eingeblendetes Wort, das
        // sagte, was gerade gilt. Es kam bei jedem Griff, stand im Bild und
        // musste weggetippt werden -- was passiert, sieht man ohnehin.
        //
        // **Und ohne mitziehende Animation.** Ein Versuch, das Bild waehrend
        // der Geste per `scaleEffect` mitlaufen zu lassen, hat es
        // verschlechtert: der Zoom lief nicht mehr voll durch, und das
        // `clipped()` dazu sass ausserhalb von `ignoresSafeArea` und
        // beschnitt das Bild am sicheren Bereich statt am Bildschirmrand.
        // Zurueckgenommen -- ein harter, richtiger Wechsel ist besser als
        // ein weicher, der danebenliegt.
        //
        // `simultaneousGesture`, damit Tippen und Spulen darunter weiter
        // treffen. Der Riegel ist noetig, weil `onChanged` waehrend einer
        // Geste dutzendfach feuert: ohne ihn haette ein einziges
        // Auseinanderziehen zwischen beiden Zustaenden geflackert.
        .simultaneousGesture(
            MagnifyGesture(minimumScaleDelta: 0.05)
                .onChanged { wert in
                    guard !zoomSchonGeschaltet, !imKleinenFenster else { return }
                    if wert.magnification > 1.15, !bildfuellend {
                        zoomSchonGeschaltet = true
                        bildfuellend = true
                        surface?.bildfuellend(true)
                    } else if wert.magnification < 0.85, bildfuellend {
                        zoomSchonGeschaltet = true
                        bildfuellend = false
                        surface?.bildfuellend(false)
                    }
                }
                .onEnded { _ in zoomSchonGeschaltet = false }
        )
        // Beim Oeffnen und beim Folgenwechsel den gemerkten Zustand anlegen.
        .onChange(of: surface == nil) { _, _ in surface?.bildfuellend(bildfuellend) }
        // **Im Hintergrund laeuft weiter.** Das ist eine Entscheidung, keine
        // Unterlassung.
        //
        // Hier stand eine Regel, die beim Wechsel in den Hintergrund anhielt
        // -- gegen den Fall, dass eine weggewischte Folge unbemerkt
        // durchlaeuft und danach als gesehen dasteht (jellyfin/Swiftfin#871,
        // Rueckfall #2175). Sie hat einen echten Fehler erzeugt: iOS schickt
        // die App auch dann in den Hintergrund, wenn nur die
        // Mitteilungszentrale heruntergezogen wird, und zwar durch **genau
        // dieselbe** Folge von Meldungen wie bei einem Wisch auf den
        // Homescreen (am 08.09.2026 mitgeschrieben: willResignActive →
        // scenePhase inactive → didEnterBackground). Kein Signal trennt die
        // beiden Faelle. Jeder Blick auf eine Mitteilung hielt den Film an,
        // und er lief auch nicht von selbst wieder los.
        //
        // Andere Clients erlauben schlicht die Hintergrundwiedergabe, und die
        // App erklaert `UIBackgroundModes: audio` ohnehin -- ohne sie gaebe
        // es kein Bild-im-Bild und keinen Sperrbildschirm. Also laeuft es
        // weiter, und der Fortschritt wird wie sonst im Takt gemeldet.
        //
        // Die Lebenslage wird weiter mitgeschrieben: das kostet in der
        // ausgelieferten Fassung nichts (`Protokoll.schreib` faellt dort
        // heraus) und hat genau diesen Fehler gefunden.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didEnterBackgroundNotification)) { _ in
            Protokoll.schreib("[Lebenslage] didEnterBackground · Zustand \(Lagewort.jetzt)"
                + " · PiP \(imKleinenFenster) · laeuft \(laeuft) → weiterlaufen lassen")
            // Den Stand jetzt melden (T3 #5): wird die App doch eingefroren,
            // steht am Server sonst bis zu zehn Sekunden alte Stelle.
            if startGemeldet, !wechselt {
                model.hintergrundMelden(item: item, plan: plan, seconds: position, paused: !laeuft)
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)) { _ in
            Protokoll.schreib("[Lebenslage] willEnterForeground · Zustand \(Lagewort.jetzt)")
        }
        .task { await beobachten() }
        // Erst danach steht fest, ob es einen „Weiter"-Knopf geben darf.
        .task { await nachschlagen(fuer: item) }
        .onChange(of: dauer) { _, _ in zentraleMelden() }
        .onAppear {
            model.playerOffen = true
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
                model.fertigGeschaut(position: stelle, dauer: dauer)
                surface?.stop()
                zentrale.abgeben()
                // Ueber den Wechsel: laeuft gerade einer, bricht er ab, und ist
                // der Start der neuen Folge unterwegs, geht der Stopp danach.
                let laufend = (item: item, plan: plan)
                folgenwechsel.schliessen {
                    await model.reportStopped(item: laufend.item, plan: laufend.plan,
                                              seconds: stelle)
                }
            }
            Orientierung.shared.playerGeschlossen()
            model.playerOffen = false
        }
    }

    // MARK: - Schleier

    private var schleier: some View { Playerschleier() }

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
    /// (`require(toFail:)`), und diese knappe Drittelsekunde fuehlt sich zaeh an.
    ///
    /// **Zwei Fassungen waren schlechter als diese.** Zuerst schaltete der
    /// erste Tipp sofort und der zweite nahm es zurueck — dabei ging bei jedem
    /// Doppeltipp die Steuerung einmal auf und wieder zu. Dann wartete der
    /// Einzeltipp `doppeltipp` lang: kein Flackern mehr, aber der Player fuehlte
    /// sich traege an, weil auf den Fingerdruck eine Viertelsekunde nichts
    /// geschah (beides Paul, 17.09.2026).
    ///
    /// **Jetzt schaltet der erste Tipp sofort und nichts wird zurueckgenommen.**
    /// Der zweite Tipp spult und laesst die Steuerung so, wie der erste sie
    /// gestellt hat. Damit ist die Oberflaeche sofort da, und trotzdem wippt
    /// nichts: sie geht auf **oder** zu, nie beides hintereinander.
    private func flaeche(richtung: Int) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { tippen(richtung: richtung) }
    }

    private func tippen(richtung: Int) {
        let jetzt = Date()
        if let vorher = letzterTipp, letzteSeite == richtung,
           jetzt.timeIntervalSince(vorher) < Self.doppeltipp {
            letzterTipp = nil
            // Der erste Tipp hat schon geschaltet. Das bleibt so — was
            // einmal dasteht, wird nicht wieder weggenommen.
            if steuerungSichtbar { ausblendenVerschieben() }
            spulen(Int32(richtung < 0 ? -model.zurueckSekunden : model.vorSekunden))
            return
        }
        letzterTipp = jetzt
        letzteSeite = richtung
        steuerungUmschalten()
    }

    /// Wie lange ein Tipp auf seinen zweiten wartet.
    private static let doppeltipp: Double = 0.26

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

                // Nur der Platz: der Knopf selbst liegt in der Einblendung
                // darüber, an derselben Stelle wie ohne Steuerung.
                Angebotsknopf(angebot: angebot, aktion: {})
                    .hidden()
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white)

            Zeitzeile(position: $position, dauer: dauer) { schiebt in
                if schiebt {
                    amSchieben = true
                    zuletztGeschoben = Date()
                    ausblendMarke += 1
                } else {
                    // Ausdrücklich zurücksetzen: sonst bliebe amSchieben
                    // stehen und die Zeitanzeige würde nie mehr nachgeführt.
                    amSchieben = false
                    surface?.seek(toSeconds: position)
                    gesprungen(auf: position)
                    ausblendenVerschieben()
                }
            }

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
        ebene.gedrueckt()
        switch angebot {
        case .keiner:
            break
        case let .ueberspringen(nach, _):
            // Wie ein Sprung von Hand: Stelle setzen, springen, und die
            // Anzeige kurz nicht überschreiben lassen.
            surface?.seek(toSeconds: nach)
            gesprungen(auf: nach)
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
            surface?.seek(toSeconds: sekunden)
            gesprungen(auf: sekunden)
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
        // Gemeldet wird an VLCs Rueckmeldung (`laeuftGemeldet`), nicht hier.
    }

    private func spielenUmschalten() {
        // Kein `laeuft.toggle()` mehr: der Knopf wartet auf VLCs Meldung.
        // Siehe `laeuftGemeldet` oben.
        if laeuft { surface?.pause() } else { surface?.resume() }
        steuerungSichtbar = true
        zentrale.standNachziehen(position: position, laeuft: laeuft, tempo: tempo)
        ausblendenVerschieben()
        // Hier stand `meldeFortschritt()` und las `laeuft` vor VLCs
        // Rueckmeldung: Pause ging als „laeuft" hinaus (T1-N1). Gemeldet wird
        // jetzt an `laeuftGemeldet`.
    }

    private func spulen(_ sekunden: Int32) {
        // Das Ziel vor dem Sprung ausrechnen: von einem noch offenen Ziel aus,
        // nicht von der Stelle, an der VLC gerade noch steht.
        let ziel = Wiedergabetakt.ziel(um: Double(sekunden), stand: anzeigestand)
        surface?.jump(seconds: sekunden)
        gesprungen(auf: ziel)
        if sekunden < 0 { taktZurueck += 1 } else { taktVor += 1 }
        sprungAnzeige = (sekunden < 0 ? -1 : 1, Int(abs(sekunden)))
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            sprungAnzeige = nil
        }
        if steuerungSichtbar { ausblendenVerschieben() }
        // Gemeldet ueber `sprungGemeldet`, mit der Zielstelle statt der alten.
    }

    /// Was die Zeitleiste gerade zeigt, als Stand für die geteilten Regeln.
    private var anzeigestand: Wiedergabetakt.Stand {
        var stand = Wiedergabetakt.Stand(position: position, dauer: dauer)
        stand.sprung = sprung
        return stand
    }

    /// **Jeder Sprung, egal über welchen Weg:** Zeitleiste und Knopf stehen
    /// sofort auf dem Ziel, nicht erst, wenn VLC nachzieht (Bug 17.09.2026).
    /// Der Takt übergibt an VLCs Zeit, sobald VLC dort ist.
    private func gesprungen(auf ziel: Double) {
        var stand = anzeigestand
        Wiedergabetakt.gesprungen(&stand, ziel: ziel)
        position = stand.position
        sprung = stand.sprung
        angebotNachziehen(vergangen: 0)
        #if DEBUG
        if Sprunglauf.an { Protokoll.schreib("[Sprung] Anzeige \(String(format: "%.1f", position)) · Angebot \(angebot)") }
        #endif
    }

    /// Die Einblendung an die angezeigte Stelle anpassen. Mit `vergangen: 0`
    /// direkt nach einem Sprung, sonst einmal je Takt.
    ///
    /// - Returns: `true`, wenn der Countdown jetzt abgelaufen ist.
    @discardableResult
    private func angebotNachziehen(vergangen: Double) -> Bool {
        guard !wechselt else { return false }
        let fertig = ebene.takt(angebot: angebot,
                                karteFaellig: Abschnittslogik.karteFaellig(position: position, dauer: dauer,
                                                                           abschnitte: abschnitte,
                                                                           hatNaechsteFolge: naechsteFolge != nil),
                                laeuft: laeuft && bildFrei && !amSchieben,
                                vergangen: vergangen,
                                countdown: Abschnittslogik.countdown(position: position, dauer: dauer))
        fuellungStellen()
        return fertig
    }

    private func fuellungStellen() {
        fuellungsuhr.stellen(anteil: countdownAnteil, laeuft: laeuft && bildFrei && !amSchieben,
                             laenge: ebene.countdownLaenge)
    }

    /// Wechselt im laufenden Player zur nächsten Folge, statt zurück in die
    /// Übersicht zu springen.
    ///
    /// **Der Ablauf steht im Paket** (`Folgenwechsel`): Riegel, Stopp und Plan
    /// nebeneinander, Abbruch beim Schließen, Stopp genau einmal. Er stand
    /// dreimal von Hand hier, auf dem Fernseher und auf dem Mac, und lief
    /// auseinander (Audit 16.09.2026, T1-H1/H3/M2/M4/M6). Hier bleibt, was nur
    /// diese Ansicht weiß: welche ihrer Zustände zur Folge gehören.
    private func zurNaechstenFolge(_ folge: Item) {
        guard !wechselt else { return }
        wechselt = true
        model.fertigGeschaut(position: position, dauer: dauer)
        let alt = (item: item, plan: plan, stelle: position)
        Task {
            let ergebnis = await folgenwechsel.ausfuehren(.init(
                stoppen: { await model.reportStopped(item: alt.item, plan: alt.plan,
                                                     seconds: alt.stelle) },
                planen: { await model.plan(for: folge.id) },
                anwenden: { neuerPlan in folgeAnwenden(folge, neuerPlan) },
                starten: { neuerPlan in await model.reportStart(item: folge, plan: neuerPlan,
                                                           seconds: 0) },
                gescheitert: {
                    hinweis = String(localized: "Nächste Folge konnte nicht geladen werden.")
                    // Die alte Folge laeuft weiter, der Server kennt sie aber
                    // schon als beendet. Die Schleife meldet sie neu an.
                    startGemeldet = false
                }))
            Protokoll.schreib("[Wechsel] \(ergebnis) → \(folge.id)")

            // **Hier ist der Wechsel fertig, also faellt hier der Riegel.**
            //
            // Solange er lag, gab `angebot` `.keiner` zurueck, darueber lag
            // `if wechselt { Lader() }`, und die Schleife schwieg. Er darf
            // nicht ueber dem Nachschlag unten liegen: kommt der spaet, stuende
            // das Bild mit laufender Uhr und ohne Tasten da.
            wechselt = false
            guard ergebnis == .gewechselt else { return }
            steuerungSichtbar = true
            ausblendenVerschieben()
            await nachschlagen(fuer: folge)
        }
    }

    /// Die neue Folge übernehmen — alles, was der alten gehörte, zurück.
    private func folgeAnwenden(_ folge: Item, _ neuerPlan: PlaybackPlan) {
        item = folge
        plan = neuerPlan
        // Die geteilte Regel setzt Stelle, Spuren, Startmeldung und das erste
        // Bild zurueck. Ohne den Ladeschirm uebernaehme die Schleife im
        // naechsten Takt noch die Zeit der **alten** Folge — der Balken
        // zuckte ans Ende, und das Weiterschalten loeste gleich noch einmal
        // aus. `startGemeldet: true`, weil der Wechsel den Start meldet.
        var stand = Wiedergabetakt.Stand(position: position, dauer: dauer, laeuft: laeuft,
                                         erstesBildDa: erstesBildDa,
                                         spurenGesetzt: spurenGesetzt,
                                         startGemeldet: startGemeldet)
        Wiedergabetakt.neuerTitel(&stand, startGemeldet: true)
        position = stand.position
        sprung = stand.sprung
        erstesBildDa = stand.erstesBildDa
        spurenGesetzt = stand.spurenGesetzt
        startGemeldet = stand.startGemeldet
        titelwechsel += 1
        // Eine neue Folge fängt eine eigene Zeitrechnung an. Bliebe die alte
        // stehen, wären Notbremse und Frischefenster sofort abgelaufen — auf
        // dem Fernseher hat genau das eine Folge übersprungen.
        seitStart = Date()
        // **Nichts zeigt mehr auf die alte Folge** (T1-M4): „Nächste Folge"
        // hielt sonst bis zum Nachschlag die Folge, die jetzt läuft, und der
        // Vorspann-Knopf sprang an die Stellen der vorigen.
        naechsteFolge = nil
        abschnitte = []
        ebene.neueFolge()
        zentraleUebernehmen()
        surface?.puffer = model.pufferstufe
        surface?.play(url: neuerPlan.url, abSekunden: 0, container: neuerPlan.container,
                      untertitel: model.untertiteldateien(neuerPlan))
    }

    /// Nächste Folge und Abschnitte zum laufenden Titel — beim Öffnen und
    /// nach jedem Wechsel. Ein Ergebnis, das zu spät für seinen Titel kommt,
    /// verwirft `Folgenwechsel.nachschlagen`.
    private func nachschlagen(fuer titel: Item) async {
        await folgenwechsel.nachschlagen(holen: { await model.folgeNach(titel) },
                                         uebernehmen: { naechsteFolge = $0 })
        await folgenwechsel.nachschlagen(holen: { await model.abschnitte(fuer: titel.id) },
                                         uebernehmen: { abschnitte = $0 })
        // **Bleibt hinten.** Die Zentrale traegt den Befehl „naechste Folge",
        // und der braucht `naechsteFolge`.
        zentraleUebernehmen()
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
        var nurZeit = false

        while !Task.isCancelled {
            try? await Task.sleep(for: Wiedergabetakt.anzeigetakt)
            guard let surface else { continue }

            // **Dazwischen nur die Zeit** (Paul, 17.09.2026): im halben
            // Sekundentakt lief sie nach dem Abspielen verzögert an und zählte
            // ungleichmäßig. Dieselben Sperren wie im ganzen Takt.
            nurZeit.toggle()
            if nurZeit {
                guard !wechselt else { continue }
                stand.position = position
                stand.sprung = sprung
                stand.erstesBildDa = erstesBildDa
                Wiedergabetakt.zeitUebernehmen(&stand,
                                               gemeldet: stelltWiederHer ? surface.guteStelle : surface.positionSeconds,
                                               amSchieben: amSchieben, seitStart: seitStart)
                position = stand.position
                sprung = stand.sprung
                continue
            }

            // Sicherung: bleibt das Schieben trotzdem hängen, nach drei
            // Sekunden ohne Bewegung selbst zurücksetzen.
            if amSchieben, let zuletzt = zuletztGeschoben,
               Date().timeIntervalSince(zuletzt) > 3 {
                amSchieben = false
            }

            // Den Stand der Ansicht übernehmen: sie ändert `position`, während
            // der Finger am Regler liegt.
            stand.position = position
            stand.sprung = sprung
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

            // **Angekommen heisst angekommen.** Ob VLC am Ziel eines Sprungs
            // steht, entscheidet `Wiedergabetakt` anhand von `stand.sprung` —
            // frueher hielt hier ein Riegel die Anzeige zwei Sekunden fest,
            // auch dann, wenn VLC laengst da war (Bug 17.09.2026).
            let auftrag = Wiedergabetakt.rechnen(
                &stand,
                messung: .init(dauer: surface.durationSeconds,
                               position: surface.positionSeconds,
                               guteStelle: surface.guteStelle,
                               zeigtBild: surface.zeigtBild,
                               stelltEin: surface.stelltEin,
                               laeuft: surface.isPlaying,
                               // **Die Spurliste nur lesen, solange sie
                               // gebraucht wird.** `Wiedergabetakt` fragt
                               // `hatTonspuren` allein, bis die Spuren gesetzt
                               // sind; danach ist der Wert unbenutzt. Gelesen
                               // wurde er trotzdem -- zweimal je Sekunde, den
                               // ganzen Film lang. `player.audioTracks` baut die
                               // Liste jedes Mal neu auf, unter der Sperre des
                               // laufenden Players. Genau der Dauergriff, vor
                               // dem der Kommentar an `Bildtakt.nochNachzumessen`
                               // ein paar Zeilen weiter oben warnt; das `||`
                               // kuerzt ihn weg, sobald er nichts mehr traegt.
                               hatTonspuren: spurenGesetzt || !surface.tonspuren.isEmpty),
                stelltWiederHer: stelltWiederHer,
                amSchieben: amSchieben,
                seitStart: seitStart)

            position = stand.position
            sprung = stand.sprung
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
                                        automatisch: model.untertitelAutomatisch,
                                        quelle: plan.quelle,
                                        titel: Spurgedaechtnis.titel(fuer: item))
            }
            if auftrag.spurenAnwenden { surface.kanaeleNachmessen() }
            // Waehrend des Wechsels schweigen. Sonst geht ein Fortschritt
            // fuer den **alten** Titel hinaus, nachdem sein Ende schon
            // gemeldet wurde — die Reihenfolge, die C4 zusagt, waere gebrochen.
            if auftrag.startMelden, !wechselt {
                // Die tatsaechliche Stelle, nicht das Ziel: seit der Start erst
                // gemeldet wird, wenn ein Bild steht, liegt das Einsteuern
                // dazwischen. Bei grossen Dateien sind das bis zu 25 Sekunden.
                model.reportStart(item: item, plan: plan, seconds: stand.position)
            }
            if auftrag.fortschrittMelden, !wechselt {
                meldeFortschritt()
                #if DEBUG
                print("[App] Position \(Int(position)) s · Dauer \(Int(dauer)) s · läuft \(laeuft) · schiebt \(amSchieben)")
                #endif
            }

            // **Die Einblendung** (Countdown der Karte). Im Stehen hält er an.
            if angebotNachziehen(vergangen: Wiedergabetakt.taktlaenge / .seconds(1)),
               let folge = naechsteFolge {
                Protokoll.schreib("[Angebot] Countdown abgelaufen")
                zurNaechstenFolge(folge)
            }
            #if DEBUG
            if Sprunglauf.an { sprungtaktSchreiben(vlc: surface.positionSeconds) }
            #endif

            // Am Ende von selbst weiter — nur mit Karte (Abspann-Abschnitt vom
            // Server), und nicht, wenn sie abgesagt wurde. Der Schalter
            // „Nächste Folge automatisch" spielt dafür keine Rolle mehr
            // (Paul, 17.09.2026).
            if ebene.weiterAmEnde, let folge = naechsteFolge, !wechselt,
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

    #if DEBUG
    /// Eine Zeile je Takt für den `Sprunglauf`.
    private func sprungtaktSchreiben(vlc: Double) {
        Protokoll.schreib("[Sprungtakt] Anzeige \(String(format: "%.1f", position))"
            + " · VLC \(String(format: "%.1f", vlc)) · Angebot \(angebot) · Ebene \(ebene.anzeige)")
    }
    #endif

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
            springenAuf: { ziel in surface?.seek(toSeconds: ziel); gesprungen(auf: ziel) },
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


    /// Setzt nur ab; die Reihe im Modell sendet (T1-H2).
    private func meldeFortschritt() {
        model.reportProgress(item: item, plan: plan, seconds: position, paused: !laeuft)
    }

    private func zeit(_ sekunden: Double) -> String { Spielzeit.text(sekunden) }

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
    /// Wird durchgereicht statt hier geholt: diese Ansicht kennt das Modell
    /// nicht, und sie soll es auch nicht kennen.
    let puffer: Pufferstufe
    /// Externe Untertitel, ebenfalls vor `play` (T1-H4).
    var untertitel: [Untertiteldatei] = []
    @Binding var pipAvailable: Bool
    let onCreate: (VLCPlayerView) -> Void

    func makeUIView(context: Context) -> VLCPlayerView {
        let view = VLCPlayerView()
        view.onPiPAvailable = { pipAvailable = $0 }
        // Vor dem Start setzen, nicht danach: die Optionen haengen am Medium,
        // und das entsteht in `play`.
        view.puffer = puffer
        view.play(url: url, abSekunden: startAt, container: container, untertitel: untertitel)
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


/// **Abdunkeln plus Verlauf oben und unten — ohne eine einzige Eingabe.**
///
/// Ohne den Schleier sind weisse Symbole ueber hellen Szenen nicht zu
/// erkennen.
///
/// Als berechnete Eigenschaft stand er im `body` von `PlayerScreen` und wurde
/// damit bei **jedem** Takt neu gerechnet — zweimal je Sekunde, mitsamt drei
/// Verlaeufen, waehrend VLC Bilder liefert. Als eigener Typ **ohne
/// gespeicherte Werte** vergleicht SwiftUI die Eingaben, findet keine, die
/// sich geaendert haetten, und laesst `body` aus.
private struct Playerschleier: View {
    var body: some View {
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
}

/// **Zeitanzeige, Regler und Restzeit — der einzige Teil, den der Takt angeht.**
///
/// `Wiedergabetakt.taktlaenge` ist 500 ms, und jeder Takt schreibt `position`.
/// Stand das hier im `body` von `PlayerScreen`, zog jeder Takt den ganzen Baum
/// hindurch: Kopf, Mittelsteuerung, Tippflaechen, Gesten. Als eigener Typ ist
/// die Zeit auf diese drei Zeilen begrenzt.
private struct Zeitzeile: View {
    @Binding var position: Double
    let dauer: Double
    /// `true` beim Anfassen, `false` beim Loslassen.
    let schiebt: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(Spielzeit.text(position))
            Zeitregler(wert: $position, bis: max(dauer, 1), beimSchieben: schiebt)
            Text("−" + Spielzeit.text(max(dauer - position, 0)))
        }
        .font(.system(size: 13).monospacedDigit())
        .foregroundStyle(.white.opacity(0.9))
    }
}

/// **„Vorspann ueberspringen" / „Naechste Folge" — derselbe Knopf.**
///
/// Eigener Typ, weil `angebot` aus `position` und `dauer` gerechnet wird und
/// sich damit bei jedem Takt neu ergibt.
///
/// **Uebersprungen wird er dadurch nicht.** `Knopfangebot` ist zwar
/// `Equatable`, der Abschluss `aktion` aber nicht — und SwiftUI vergleicht
/// die Ansicht Feld fuer Feld. Ein Funktionsfeld laesst sich nicht
/// vergleichen, also wird neu gezeichnet. Der Gewinn hier ist, dass die
/// Arbeit auf diesen Knopf begrenzt bleibt statt im `body` des Players zu
/// stehen; wer sie wirklich sparen will, muesste `aktion` durch etwas
/// Vergleichbares ersetzen. Dasselbe gilt fuer `Zeitzeile` — die soll bei
/// jedem Takt neu, das ist ihre Aufgabe.
///
/// **Der Einzige, der wirklich uebersprungen wird, ist `Playerschleier`:**
/// er hat gar keine gespeicherten Werte.
private struct Angebotsknopf: View {
    let angebot: Knopfangebot
    /// Countdown bis zur nächsten Folge — als Füllung von links, aus der Uhr
    /// gerechnet und bei jedem Bild nachgezogen, nicht im Takt.
    var fuellung: Fuellungsuhr? = nil
    /// Sekunden bis zum Wechsel, für VoiceOver.
    var rest: Int = 0
    let aktion: () -> Void

    var body: some View {
        if angebot.sichtbar {
            Button(action: aktion) {
                // Serverdaten sind hier nicht im Spiel, aber die Beschriftung
                // entsteht als `String` im Paket — deshalb `Text(verbatim:)`
                // statt `Label(_:)`, sonst wuerde sie ein zweites Mal
                // nachgeschlagen.
                HStack(spacing: 6) {
                    Image(systemName: angebot.zeichen)
                    Text(verbatim: angebot.beschriftung)
                }
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 15)
                .frame(height: 34)
                .background {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Stil.schrift.opacity(0.16))
                        if let fuellung {
                            // **Durchgehend statt im Takt** (Paul, 17.09.2026):
                            // im halben Sekundentakt nachgezogen ruckelte sie am
                            // Anfang und gegen Ende. **In Akzentfarbe**, weil sie
                            // Fortschritt ist (GESTALTUNG A); halb deckend, damit
                            // die weiße Schrift darüber lesbar bleibt — voll
                            // deckend läge sie bei knapp 2:1.
                            TimelineView(.animation) { zeit in
                                GeometryReader { g in
                                    Rectangle()
                                        .fill(Stil.akzent.opacity(0.5))
                                        .frame(width: g.size.width * fuellung.anteil(jetzt: zeit.date))
                                }
                            }
                        }
                    }
                    .clipShape(Capsule())
                }
                .overlay(Capsule().strokeBorder(Stil.schrift.opacity(0.24)))
            }
            .foregroundStyle(Stil.schrift)
            .fixedSize()
            .accessibilityLabel(Text(verbatim: angebot.beschriftung))
            .accessibilityValue(fuellung.map {
                _ in Text("Startet in \(rest) Sekunden")
            } ?? Text(verbatim: ""))
        }
    }
}
