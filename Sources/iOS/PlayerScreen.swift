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
    let startItem: Item
    let startPlan: PlaybackPlan
    let startAt: Double

    @Environment(\.dismiss) private var dismiss

    // Laufender Titel — ändert sich, wenn zur nächsten Folge gewechselt wird.
    @State private var item: Item
    @State private var plan: PlaybackPlan

    @State private var surface: VLCPlayerView?
    @State private var pipAvailable = false
    @State private var stelltWiederHer = false
    /// Läuft gerade im kleinen Fenster.
    @State private var imKleinenFenster = false
    @State private var erstesBildDa = false
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
    private var steuerungDa: Bool {
        steuerungSichtbar && erstesBildDa && !imKleinenFenster && !zeigeEinstellungen
    }
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
        self.startItem = item
        self.startPlan = plan
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

            if !erstesBildDa { startschleier }
            if imKleinenFenster { kleinerHinweis }
            if stelltWiederHer { verbindungsHinweis }

            // Erst wenn das Bild steht — sonst liegt die Steuerung ueber dem
            // Ladeschirm, und das sieht nach zwei Bildschirmen gleichzeitig aus.
            // Nicht zusätzlich zum Wiedergabemenü: sonst scheinen Kopf und
            // Fuß des Players durch und überlagern dessen Kopfzeile.
            Group {
                schleier
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

            if zeigeEinstellungen {
                PlayerSettingsSheet(surface: surface, offen: $zeigeEinstellungen,
                                    tempo: $tempo, schlafminuten: $schlafminuten,
                                    querformatFest: $querformatFest)
                    .transition(.opacity)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // Am Stapel gemessen, nicht an der Videofläche: die meldet nach der
        // Rückkehr aus Bild-im-Bild noch die Größe des kleinen Fensters.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { neu in
            fensterbreite = neu
        }
        .onAppear { model.fernbefehl = ausfuehren }
        .onDisappear { model.fernbefehl = nil }
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
        .task { await beobachten() }
        .task {
            naechsteFolge = await model.folgeNach(item)
            // Erst jetzt steht fest, ob es einen „Weiter"-Knopf geben darf.
            zentraleUebernehmen()
        }
        .onChange(of: dauer) { _, _ in zentraleMelden() }
        .onAppear { Orientierung.shared.playerGeoeffnet(querformatFest: querformatFest) }
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

                if let naechsteFolge, !wechselt, gegenEnde {
                    Button { zurNaechstenFolge(naechsteFolge) } label: {
                        Label("Nächste Folge", systemImage: "forward.end.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 15)
                            .frame(height: 34)
                            .background(.white.opacity(0.16), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.24)))
                    }
                    .foregroundStyle(.white)
                    .fixedSize()
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
                        sprungBis = Date().addingTimeInterval(2)
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

    /// Der Knopf erscheint erst, wenn die Folge fast durch ist — sonst stünde
    /// er bei einem Zweistünder zwei Stunden lang im Weg.
    ///
    /// Die Zahlen stehen in `Folgenende`, geteilt mit den anderen
    /// Plattformen, damit der Knopf überall zur selben Zeit auftaucht.
    private var gegenEnde: Bool {
        Folgenende.knopfZeigen(position: position, dauer: dauer)
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
            sprungBis = Date().addingTimeInterval(2)
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
        if laeuft { surface?.pause() } else { surface?.resume() }
        withAnimation(.easeOut(duration: 0.12)) { laeuft.toggle() }
        steuerungSichtbar = true
        zentrale.standNachziehen(position: position, laeuft: laeuft, tempo: tempo)
        ausblendenVerschieben()
        meldeFortschritt()
    }

    private func spulen(_ sekunden: Int32) {
        surface?.jump(seconds: sekunden)
        sprungBis = Date().addingTimeInterval(1.5)
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
            zentraleUebernehmen()
            wechselt = false
            steuerungSichtbar = true
            ausblendenVerschieben()
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
               Folgenende.weiterschalten(position: position, dauer: dauer) {
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
                        sprungweite: (model.zurueckSekunden, model.vorSekunden))
    }

    private func meldeFortschritt() {
        Task {
            await model.reportProgress(item: item, plan: plan,
                                       seconds: position, paused: !laeuft)
        }
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
