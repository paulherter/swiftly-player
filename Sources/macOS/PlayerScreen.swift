import AppKit
import JellyfinKit
import SwiftUI

/// Der Player im Fenster.
///
/// Verhalten wörtlich aus der iPhone-Fassung: die Steuerung zieht sich nach
/// vier Sekunden Ruhe zurück, nicht im Pausenzustand; 10 s zurück, 30 s vor.
///
/// **Anders als auf dem iPhone**, und zwar wegen der Eingabeart:
/// - Die Steuerung erscheint, wenn der Zeiger sich bewegt, nicht auf Tippen.
/// - Die Doppeltipp-Drittel entfallen; gespult wird mit den Pfeiltasten.
/// - Statt Bild-im-Bild gibt es das kleine Fenster. Das ist keine Wahl,
///   sondern ein Befund: VLC gibt auf macOS keine `AVSampleBufferDisplayLayer`
///   heraus, siehe CLAUDE.md.
struct PlayerScreen: View {
    let model: AppModel
    let anfang: Abspielwunsch
    let schliessen: () -> Void

    /// Titel und Plan wandern beim Folgenwechsel weiter — der Player bleibt
    /// stehen, nur was er spielt, ändert sich.
    @State private var titel: Item
    @State private var plan: PlaybackPlan
    @State private var naechsteFolge: Item?
    /// Vorspann, Rückblick, Abspann — leer, wenn der Server nichts weiß.
    @State private var abschnitte: [JellyfinKit.Abschnitt] = []
    @State private var wechselt = false
    @State private var hinweis: String?
    @State private var flaeche: VLCPlayerView?
    @State private var stand: Wiedergabetakt.Stand

    /// **Was der Knopf zeigt, bis der Takt nachkommt.**
    ///
    /// `stand.laeuft` kommt aus dem Takt, und der schlägt alle 500 ms
    /// (`Wiedergabetakt.taktlaenge`). Der Knopf hing daran — er sprang also
    /// erst bis zu einer halben Sekunde nach dem Klick um. Zusammen mit dem
    /// Bild, das seinerseits einen Moment nachzieht, wirkt das, als reagiere
    /// der Player gar nicht.
    ///
    /// Gesetzt wird er von `VLCPlayerView.laeuftGemeldet`, also in dem
    /// Moment, in dem VLC selbst umschaltet — gemessen 17 bis 25 ms nach dem
    /// Druck. Damit sind Knopf und Bild gleichzeitig still.
    @State private var laeuftAnzeige: Bool?

    private var laeuftJetzt: Bool { laeuftAnzeige ?? stand.laeuft }
    @State private var amRegler = false
    @State private var spurwahlOffen = false
    /// Wo der Zeiger zuletzt stand. Ohne diesen Vergleich stellt jeder
    /// Neuzeichenvorgang den Wecker zurück — und die Schleife zeichnet alle
    /// 500 ms neu, der Wecker läuft also nie ab.
    @State private var zeigerZuletzt: CGPoint?
    @State private var tempo: Float = 1
    /// Nur für die Blende — `stand.erstesBildDa` sagt, *ob*, dieses Merkmal
    /// sorgt dafür, dass das Wegnehmen weich läuft.
    @State private var schirmWeg = false
    /// Bis wann nach einem Sprung die Zeit **nicht** übernommen wird.
    ///
    /// Sonst springt der Regler auf den alten Wert zurück, bevor VLC
    /// nachgezogen hat — derselbe Fall wie die Null beim Öffnen: ein Wert
    /// steht bereit, bevor VLC ihn bestätigt hat.
    @State private var sprungBis: Date?
    /// Welcher Sprung gerade quittiert wird — Richtung und Weite.
    ///
    /// Die iPhone- und iPad-Fassung zeigen beim Springen eine Marke am Rand
    /// (`Sprungmarke`). Auf dem Mac fehlte sie: dort hat man Knöpfe und
    /// Pfeiltasten, aber auch dann will man sehen, **dass** gesprungen wurde
    /// und wie weit — sonst wirkt eine Taste ohne Wirkung, bis das Bild
    /// nachzieht.
    @State private var sprungAnzeige: (richtung: Int, sekunden: Int)?
    @State private var sprungTakt = 0
    /// **Die Videofläche beim Schliessen zuerst ausblenden.**
    ///
    /// Der Videoausgang ist auf dem Mac ein `VLCOpenGLVideoView`. Der
    /// Kommentar bei `Videoflaeche` sagt schon, was das bedeutet: eine
    /// OpenGL-Ansicht zeichnet in ihre **eigene** Fläche und liegt über
    /// allem, was im SwiftUI-Stapel nach ihr kommt — die Reihenfolge im
    /// `ZStack` entscheidet nichts.
    ///
    /// Für die Schliessbewegung heisst das: die SwiftUI-Ebenen fahren
    /// ordentlich nach unten, die OpenGL-Fläche bleibt aber liegen, bis
    /// SwiftUI die Ansicht wirklich abräumt. Genau das sieht man — „darunter
    /// ist dann einfach nur eine schwarze Ebene, die nach ein paar Sekunden
    /// wieder weg ist".
    ///
    /// `isHidden` wirkt auf AppKit-Ebene und damit sofort. Also erst
    /// ausblenden, dann fahren.
    @State private var flaecheAus = false
    /// Je Richtung ein eigener Zähler — sonst spielt der Effekt am falschen
    /// Knopf, wenn man abwechselnd vor und zurück springt.
    @State private var taktZurueck = 0
    @State private var taktVor = 0
    @State private var schlafminuten: Int?
    @State private var schlafAufgabe: Task<Void, Never>?
    @State private var seitStart = Date()
    @State private var steuerungDa = true
    @State private var halter = Fensterhalter()
    @State private var zentrale = Wiedergabezentrale()
    @State private var ruheAufgabe: Task<Void, Never>?

    init(model: AppModel, wunsch: Abspielwunsch, schliessen: @escaping () -> Void) {
        self.model = model
        self.anfang = wunsch
        self.schliessen = schliessen
        _titel = State(initialValue: wunsch.item)
        _plan = State(initialValue: wunsch.plan)
        // **Die Uhr fängt an der Fortsetzungsstelle an, nicht bei null.**
        //
        // `Stand()` beginnt bei 0, und diese Null wird zweieinhalb Sekunden
        // lang gerechnet, bis VLC eingesteuert hat. Sie zu verdecken genügt
        // nicht: der Zeitregler wäre in dieser Zeit an eine Null gebunden —
        // ein Zug daran spränge gegen 0 statt gegen die echte Stelle —, und
        // `Folgenende.knopfZeigen` bekäme sie ebenfalls, was bei einer zu
        // 97 % gesehenen Folge den Unterschied macht.
        //
        // Die iPhone-Fassung tut dasselbe (`_position = State(initialValue: startAt)`).
        _stand = State(initialValue: .init(position: wunsch.startAt))
    }

    var body: some View {
        ZStack {
            Color.black

            Videoflaeche(url: anfang.plan.url, startAt: anfang.startAt,
                         container: anfang.plan.container,
                         verdeckt: !schirmWeg || flaecheAus) { neu in
                flaeche = neu
                // Der Knopf hängt an VLCs eigener Meldung, nicht am Takt und
                // nicht am Klick — siehe `laeuftAnzeige`.
                neu.laeuftGemeldet = { laeuft in laeuftAnzeige = laeuft }
            }
            .ignoresSafeArea()
            // Ohne das nimmt die Animation der Steuerung die Videofläche mit
            // — sie wuchs bei jedem Einblenden sichtbar von klein auf groß.
            // Eine Narbe der iPhone-Fassung, die mit Bild-im-Bild nichts zu
            // tun hat und uns genauso trifft.
            .transaction { $0.animation = nil }

            // **Deckend**, nicht nur ein Rädchen. Vorher stand hier ein
            // durchsichtiger `Lader()`, und das Video lief die ganze Zeit
            // sichtbar darunter — man sah VLC an den Anfang gehen und von
            // dort an die gemerkte Stelle steuern. Die Regeln in
            // `Zeitannahme.bildDa` waren richtig; es fehlte schlicht der
            // Schirm, den sie wegnehmen sollten.
            if !schirmWeg { startschleier }

            // **Erst wenn das Bild steht.** Sonst liegt die Steuerung über dem
            // Ladeschirm und zeigt 0:00 mit leerer Leiste, während VLC noch
            // einsteuert — es sieht dann so aus, als liefe der Film von vorn.
            // Genau das hat Paul gemeldet, und die Zeile steht seit jeher in
            // der iPhone-Fassung; ich hatte sie nicht gelesen.
            // Die Sprungmarke steht **unabhängig von der Steuerung**: wer mit
            // den Pfeiltasten springt, hat sie meist gar nicht offen.
            if schirmWeg, let sprungAnzeige {
                HStack(spacing: 0) {
                    if sprungAnzeige.richtung > 0 { Spacer() }
                    Sprungmarke(richtung: sprungAnzeige.richtung,
                                sekunden: sprungAnzeige.sekunden)
                        // Ohne eigene Kennung baut SwiftUI die Ansicht bei
                        // zwei Sprüngen hintereinander nicht neu — die
                        // Drehung bliebe aus.
                        .id(sprungTakt)
                    if sprungAnzeige.richtung < 0 { Spacer() }
                }
                .padding(.horizontal, 44)
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if schirmWeg, steuerungDa {
                steuerung.transition(.opacity)
            }
        }
        .background(Fensterzugriff(halter: halter))
        // Der Zeiger ruft die Steuerung — nicht ein Klick. Ein Klick ins Bild
        // täte auf dem Mac nichts Erwartbares.
        // `onContinuousHover` meldet nicht nur Bewegung, sondern auch jedes
        // Neuzeichnen mit unveränderter Stelle. Deshalb der Vergleich: nur
        // eine wirkliche Bewegung ruft die Steuerung.
        .onContinuousHover { lage in
            guard case let .active(stelle) = lage else {
                // **Zeiger raus aus dem Fenster: sofort weg.**
                //
                // Die vier Sekunden sind dafür da, dass die Steuerung nicht
                // unter der Hand verschwindet, während man sie noch braucht.
                // Ist der Zeiger gar nicht mehr im Fenster, braucht sie
                // niemand — dann ist Warten nur Verzögerung. In Pause bleibt
                // sie stehen: dort ist sie kein Überbleibsel, sondern der
                // Zustand.
                zeigerZuletzt = nil
                halter.setzeZeigerOben(false)
                if stand.laeuft, !amRegler { steuerungSofortWeg() }
                return
            }
            defer { zeigerZuletzt = stelle }
            // **Die Fensterampel hängt an dieser Zone, nicht an der
            // Steuerung.** Sie steht sonst dauerhaft über dem Bild und ist
            // im Weg. So kommt sie, wenn man sie sucht — oben — und bleibt
            // sonst fort.
            halter.setzeZeigerOben(stelle.y < Stil.ampelzone)
            guard let vorher = zeigerZuletzt else { return }
            let weg = hypot(stelle.x - vorher.x, stelle.y - vorher.y)
            if weg > 2 { steuerungZeigen() }
        }
        .onAppear { steuerungZeigen() }
        .onAppear {
            zentraleUebernehmen()
            // **Auch die Fernsteuerung, nicht nur der Sperrbildschirm.**
            //
            // Beide bekommen dieselben Griffe, sie kommen nur aus
            // verschiedenen Richtungen: die Zentrale von den Medientasten
            // dieses Rechners, `fernbefehl` über Jellyfins Socket von einem
            // anderen Gerät. Auf dem Mac fehlte die zweite Hälfte ganz —
            // Paul: „wenn ich dort abspiele, wird nicht erkannt, dass ich
            // dort abspiele, und man kann von außen nicht pausieren."
            model.fernbefehl = ausfuehren
            halter.setzePlayer(true)
        }
        .onChange(of: stand.laeuft) { _, neu in
            if laeuftAnzeige == neu { laeuftAnzeige = nil }
        }
        .onChange(of: tempo) { tempoAnwenden() }
        .onChange(of: schlafminuten) { schlafzeitSetzen(schlafminuten) }
        .task {
            naechsteFolge = await model.folgeNach(titel)
            abschnitte = await model.abschnitte(fuer: titel.id)
        }
        .onDisappear {
            ruheAufgabe?.cancel()
            schlafAufgabe?.cancel()
            halter.aufraeumen()
            zentrale.abgeben()
            model.fernbefehl = nil
            // Der Zeiger gehört zurück, sobald der Player weg ist.
            NSCursor.unhide()
        }
        .task { await mitlaufen() }
        // Tastenkürzel. Sie stehen zusätzlich in der Menüleiste, damit man sie
        // findet, ohne sie zu kennen.
        .background {
            VStack {
                Button("") { umschalten() }.keyboardShortcut(.space, modifiers: [])
                Button("") { springe(-Double(model.zurueckSekunden)) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { springe(Double(model.vorSekunden)) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { fluchttaste() }.keyboardShortcut(.escape, modifiers: [])
                // „Kleines Fenster" ist vorerst aus der Oberfläche raus;
                // der Kurzbefehl geht mit, sonst gäbe es einen Weg dorthin,
                // aus dem man nicht zurückfindet.
                Button("") { }
                    .keyboardShortcut("p", modifiers: [.command, .option])
            }
            .opacity(0)
        }
    }

    private var startschleier: some View {
        ZStack {
            Color.black
            Lader()
        }
        .ignoresSafeArea()
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    // MARK: Steuerung

    private var steuerung: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.60), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 150)
                .frame(maxHeight: .infinity, alignment: .top)
            LinearGradient(colors: [.clear, .black.opacity(0.70)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 230)
                .frame(maxHeight: .infinity, alignment: .bottom)

            VStack(spacing: 0) {
                kopf
                Spacer()
                mitte
                Spacer()
                fuss
            }
        }
        .allowsHitTesting(true)
    }

    /// Links der Weg zurück, rechts die Werkzeuge — wie auf dem iPhone.
    ///
    /// **Die Fensterampel ist ausgeblendet, solange der Player oben ist**
    /// (siehe `Fensterhalter`). Sonst stünden hier zwei Schließer
    /// nebeneinander mit verschiedener Wirkung: der Winkel legt den Player
    /// weg und bringt einen auf die Detailseite zurück, die rote Lampe
    /// schließt die ganze Sitzung. Zwei Handlungen an derselben Ecke.
    private var kopf: some View {
        HStack(spacing: 0) {
            // **Links steht nichts mehr.** Der Winkel sass dort neben der
            // Fensterampel; jetzt hat sie die Ecke für sich. Geschlossen wird
            // rechts, bei den übrigen Werkzeugen.
            //
            // „Kleines Fenster" ist vorerst raus — die Maschinerie dahinter
            // (`Fensterhalter.setzeKlein`) bleibt stehen, sie ist nur nicht
            // mehr erreichbar.
            Spacer(minLength: 0)
            Chip(beschriftung: String(localized: "Ton und Untertitel"),
                 symbol: "slider.horizontal.3", aktiv: spurwahlOffen) {
                withAnimation(Stil.zeitSprung) { spurwahlOffen.toggle() }
            }
            .padding(.leading, 12)
            // Die Tafel klappt unter dem Knopf auf — kleine Entscheidungen
            // bleiben am Ort. Die Wiedergabe läuft dabei weiter.
            .overlay(alignment: .topTrailing) {
                if spurwahlOffen, let flaeche {
                    Spurwahl(tonspuren: flaeche.tonspuren,
                             untertitel: flaeche.untertitelspuren,
                             gewaehlterTon: flaeche.gewaehlteTonspur?.trackName,
                             gewaehlterUntertitel: flaeche.gewaehlterUntertitel?.trackName,
                             tempo: $tempo, schlafminuten: $schlafminuten,
                             waehleTon: { flaeche.waehleTonspur($0); steuerungZeigen() },
                             waehleUntertitel: { flaeche.waehleUntertitel($0); steuerungZeigen() })
                        .offset(y: 46)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            // Der Winkel zeigt nach unten, weil der Player von unten
            // aufsteigt und wieder dorthin verschwindet. Das Zeichen
            // beschreibt eine Bewegung, die es hier wirklich gibt.
            Chip(beschriftung: String(localized: "Schließen"),
                 symbol: "chevron.down", aktiv: false) { beenden() }
                .padding(.leading, 12)
        }
        .padding(.trailing, 22)
        // **Auf derselben Linie wie der Titel unten.**
        //
        // Die Ampel brauchte keinen Platz: sie sitzt oben bei 16, der Winkel
        // gut fünfzig Punkt tiefer — sie stossen gar nicht aneinander. Die 74
        // Punkt, die ich dafür freigehalten hatte, haben ihn nur nach rechts
        // geschoben.
        //
        // 28 ist der Rand der unteren Zeile; die zwölf Punkt Abzug sind der
        // Innenabstand des runden Knopfes, damit das Zeichen selbst auf der
        // Linie steht und nicht sein Rahmen.
        .padding(.leading, 28 - 12)
        .padding(.top, 18)
    }

    private var mitte: some View {
        HStack(spacing: 52) {
            Sprungknopf(symbol: "gobackward.\(model.zurueckSekunden)", gross: false,
                        kuerzel: "←", takt: taktZurueck) {
                springe(-Double(model.zurueckSekunden))
            }
            Sprungknopf(symbol: laeuftJetzt ? "pause.fill" : "play.fill", gross: true,
                        kuerzel: String(localized: "Leertaste"), flott: true) {
                umschalten()
            }
            Sprungknopf(symbol: "goforward.\(model.vorSekunden)", gross: false,
                        kuerzel: "→", takt: taktVor) {
                springe(Double(model.vorSekunden))
            }
        }
    }

    /// Titel unten, nicht oben: er gehört zur Zeitleiste, nicht zu den
    /// Werkzeugen. Wörtlich die Aufteilung der iPhone-Fassung.
    private var fuss: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: titel.name)
                        .font(.system(size: 19, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let kontext = titel.kontextzeile { Text(verbatim: kontext) }
                        // **Die Abweichung meldet sich, wo man sie merkt.**
                        // Dass der Server nicht transkodiert, ist der Grund
                        // für diese App; der Player ist die Stelle, an der es
                        // auffällt. Stand bei mir nur auf der Detailseite.
                        if !plan.isLossless {
                            Label(plan.method.rawValue,
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Stil.warnung)
                        }
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(Stil.schrift.opacity(0.68))
                    .lineLimit(1)
                }

                Spacer(minLength: 0)

                // Erscheint erst gegen Ende — die Zahlen stehen in
                // `Folgenende` und gelten auf allen Plattformen.
                if angebot.sichtbar {
                    Chip(beschriftung: angebot.beschriftung,
                         symbol: angebot.zeichen, aktiv: false,
                         auswahl: angebotAusfuehren)
                }
            }
            .foregroundStyle(Stil.schrift)

            HStack(spacing: 14) {
                Text(verbatim: Spielzeit.text(stand.position))
                    .font(.system(size: 13)).monospacedDigit()
                    .foregroundStyle(Stil.schrift.opacity(0.68))

                Zeitregler(position: $stand.position, dauer: stand.dauer,
                           amRegler: $amRegler) { ziel in
                    flaeche?.seek(toSeconds: ziel)
                    sprungBis = Date().addingTimeInterval(Zeitannahme.sprungriegel)
                }

                Text(verbatim: "-" + Spielzeit.text(stand.dauer - stand.position))
                    .font(.system(size: 13)).monospacedDigit()
                    .foregroundStyle(Stil.schrift.opacity(0.68))
            }

            // Der Hinweis steht unter dem Regler, nicht oben im Bild.
            if let hinweis {
                Text(verbatim: hinweis)
                    .font(.system(size: 12))
                    .foregroundStyle(Stil.schrift.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 26)
    }

    // MARK: Handlungen

    /// Läuft die Zeit ab, wird angehalten und gesagt warum — nicht einfach
    /// stillgestellt. Wörtlich die iPhone-Fassung.
    private func schlafzeitSetzen(_ minuten: Int?) {
        schlafAufgabe?.cancel()
        guard let minuten else { return }
        schlafAufgabe = Task {
            try? await Task.sleep(for: .seconds(minuten * 60))
            guard !Task.isCancelled else { return }
            flaeche?.pause()
            steuerungZeigen()
            melde(String(localized: "Schlafzeit abgelaufen."))
        }
    }

    /// Das Tempo liegt in der Ansicht, damit die Tafel es binden kann — VLC
    /// bekommt es beim Wechsel durchgereicht.
    private func tempoAnwenden() {
        guard let flaeche, flaeche.tempo != tempo else { return }
        flaeche.tempo = tempo
    }

    private func umschalten() {
        guard let flaeche else { return }
        if flaeche.isPlaying { flaeche.pause() } else { flaeche.resume() }
        steuerungZeigen()
    }

    private func springe(_ sekunden: Double) {
        flaeche?.jump(seconds: Int32(sekunden))
        sprungBis = Date().addingTimeInterval(Zeitannahme.sprungriegel)
        steuerungZeigen()

        if sekunden < 0 { taktZurueck += 1 } else { taktVor += 1 }
        sprungTakt += 1
        let takt = sprungTakt
        withAnimation(.easeInOut(duration: 0.15)) {
            sprungAnzeige = (sekunden < 0 ? -1 : 1, Int(abs(sekunden)))
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard sprungTakt == takt else { return }
            withAnimation(.easeInOut(duration: 0.15)) { sprungAnzeige = nil }
        }
    }

    /// Was ein anderes Gerät hier auslöst.
    ///
    /// Dieselben Griffe wie in ``zentraleUebernehmen``, nur über Jellyfins
    /// Socket statt über die Medientasten. `.stopp` schließt den Player —
    /// darauf verlässt sich das Übernehmen: drüben zu, hier weiter.
    private func ausfuehren(_ befehl: Fernbefehl) {
        switch befehl {
        case .pause:     flaeche?.pause()
        case .weiter:    flaeche?.resume()
        case .umschalten: umschalten()
        case .stopp:     beenden()
        case let .springenAuf(sekunden):
            flaeche?.seek(toSeconds: sekunden)
            sprungBis = Date().addingTimeInterval(Zeitannahme.sprungriegel)
        case .vor:       springe(Double(model.vorSekunden))
        case .zurueck:   springe(-Double(model.zurueckSekunden))
        case .naechste:
            if let folge = naechsteFolge { zurNaechstenFolge(folge) }
        case .vorige:    break
        }
        steuerungZeigen()
    }

    /// Welcher Knopf gerade gilt. Dieselbe Regel wie auf iOS.
    private var angebot: Knopfangebot {
        guard !wechselt else { return .keiner }
        return Abschnittslogik.angebot(position: stand.position, dauer: stand.dauer,
                                       abschnitte: abschnitte,
                                       hatNaechsteFolge: naechsteFolge != nil)
    }

    private func angebotAusfuehren() {
        switch angebot {
        case .keiner:
            break
        case let .ueberspringen(nach, _):
            flaeche?.seek(toSeconds: nach)
            sprungBis = Date().addingTimeInterval(Zeitannahme.sprungriegel)
            steuerungZeigen()
        case .naechsteFolge:
            if let folge = naechsteFolge { zurNaechstenFolge(folge) }
        }
    }

    private func beenden() {
        // **Vor** dem Anhalten ablesen — danach steht die Zeit auf null und
        // „Weiterschauen" verlöre die Stelle.
        let stelle = stand.position

        // Zuerst die OpenGL-Fläche weg, sonst bleibt sie als schwarzes
        // Rechteck liegen, während die Seite darüber hinunterfährt.
        flaecheAus = true

        // **Anhalten ja, abräumen später.**
        //
        // Hier stand `flaeche?.stop()` unmittelbar vor `schliessen()`. `stop`
        // räumt den Dekoder ab und braucht dafür sichtbar Zeit — auf dem
        // Hauptlauf, in demselben Vorgang, in dem die Bewegung nach unten
        // losfährt. Deshalb war das Öffnen weich und das Schliessen hart:
        // beim Öffnen ist nichts abzuräumen.
        //
        // `pause` ist billig und nimmt den Ton sofort weg. Das Abräumen
        // folgt, wenn die Bewegung durch ist.
        flaeche?.pause()

        if stand.startGemeldet {
            Task { await model.reportStopped(item: titel, plan: plan,
                                             seconds: stelle) }
        }
        schliessen()
        // Abgeräumt wird in `Videoflaeche.dismantleNSView`, also dann, wenn
        // SwiftUI die Ansicht wirklich entfernt — nach der Bewegung. Ein
        // eigener Wecker dafür war geraten und traf den Zeitpunkt nur
        // ungefähr.
    }

    /// Esc verlässt zuerst das Vollbild und schließt erst dann den Film.
    /// Andersherum verliert man beim Versuch, aus dem Vollbild zu kommen,
    /// die Wiedergabe — und das ist keine Kleinigkeit, wenn man mitten drin
    /// ist.
    private func fluchttaste() {
        if halter.istVollbild {
            halter.vollbildUmschalten()
        } else {
            beenden()
        }
    }

    /// Vier Sekunden Ruhe, dann zieht sie sich zurück — nicht im
    /// Pausenzustand. Dieselbe Regel wie auf dem iPhone.
    /// Ohne die vier Sekunden — für den Fall, dass der Zeiger das Fenster
    /// verlässt.
    private func steuerungSofortWeg() {
        ruheAufgabe?.cancel()
        withAnimation(.easeInOut(duration: 0.34)) {
            steuerungDa = false
            halter.setzeSteuerung(false)
            spurwahlOffen = false
        }
    }

    private func steuerungZeigen() {
        withAnimation(.easeOut(duration: 0.18)) { steuerungDa = true }
        halter.setzeSteuerung(true)
        NSCursor.unhide()
        ruheAufgabe?.cancel()
        ruheAufgabe = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, stand.laeuft, !amRegler else { return }
            withAnimation(.easeInOut(duration: 0.34)) {
                steuerungDa = false
                halter.setzeSteuerung(false)
                spurwahlOffen = false
            }
            // Der Zeiger geht mit. `setHiddenUntilMouseMoves` ist der richtige
            // Weg und nicht `hide()`: er kommt bei der nächsten Bewegung von
            // selbst zurück, ohne dass wir ihn wieder einschalten müssen —
            // und bleibt nicht verschwunden, wenn die App abstürzt.
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    /// Now Playing und die Medientasten der Tastatur. Beides läuft über
    /// `MPRemoteCommandCenter` — auf dem Mac braucht es dafür nichts Eigenes.
    private func zentraleUebernehmen() {
        seitStart = Date()
        zentrale.uebernehmen(.init(
            abspielen: { flaeche?.resume() },
            anhalten:  { flaeche?.pause() },
            umschalten: { umschalten() },
            springenAuf: { ziel in flaeche?.seek(toSeconds: ziel) },
            vor:     { springe(Double(model.vorSekunden)) },
            zurueck: { springe(-Double(model.zurueckSekunden)) },
            naechste: naechsteFolge.map { folge in { zurNaechstenFolge(folge) } }))
    }

    /// Wechselt im laufenden Player, ohne in die Übersicht zurückzuspringen —
    /// wörtlich die Regel der iPhone-Fassung.
    private func zurNaechstenFolge(_ folge: Item) {
        guard !wechselt else { return }
        wechselt = true
        Task {
            await model.reportStopped(item: titel, plan: plan, seconds: stand.position)
            guard let neuerPlan = await model.plan(for: folge.id) else {
                melde(String(localized: "Nächste Folge konnte nicht geladen werden."))
                wechselt = false
                return
            }
            titel = folge
            plan = neuerPlan
            flaeche?.play(url: neuerPlan.url, abSekunden: 0, container: neuerPlan.container)
            await model.reportStart(item: folge, plan: neuerPlan, seconds: 0)
            // **Muss sein.** Sonst bliebe `startGemeldet` auf `true` hängen und
            // der Takt meldete den nächsten Titel nie als begonnen — es kämen
            // nur noch Fortschrittsmeldungen ohne eröffnete Sitzung. Der Start
            // ist hier schon gemeldet, deshalb `true`.
            Wiedergabetakt.neuerTitel(&stand, startGemeldet: true)
            // **Auch die Uhr.** `seitStart` gehört zum Ansichtszustand, nicht
            // zum Stand — ohne das Zurücksetzen hält `Zeitannahme` die neue
            // Folge für einen alten, längst eingesteuerten Titel. Auf tvOS
            // hat genau das eine Folge übersprungen.
            seitStart = Date()
            naechsteFolge = await model.folgeNach(folge)
            // Die neue Folge hat eigene Abschnitte.
            abschnitte = await model.abschnitte(fuer: folge.id)
            zentraleUebernehmen()
            wechselt = false
        }
    }

    private func melde(_ text: String) {
        hinweis = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { hinweis = nil }
        }
    }

    /// Ein Takt alle halbe Sekunde — die Regeln stehen in
    /// `Wiedergabetakt`, gemeinsam mit iPhone und Fernseher. Hier steht nur,
    /// **wie** der Mac die vier Aufträge ausführt.
    private func mitlaufen() async {
        var takte = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: Wiedergabetakt.taktlaenge)
            guard let flaeche else { continue }

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
            if sprungBis != nil, abs(flaeche.positionSeconds - stand.position) < Zeitannahme.sprungAngekommen {
                sprungBis = nil
            }

            let auftrag = Wiedergabetakt.rechnen(
                &stand,
                messung: .init(dauer: flaeche.durationSeconds,
                               position: flaeche.positionSeconds,
                               guteStelle: flaeche.guteStelle,
                               zeigtBild: flaeche.zeigtBild,
                               stelltEin: flaeche.stelltEin,
                               laeuft: flaeche.isPlaying,
                               hatTonspuren: !flaeche.tonspuren.isEmpty),
                stelltWiederHer: false,
                sprungLaeuft: sprungBis.map { Date() < $0 } ?? false,
                // Kein Finger, aber ein Zeiger — dieselbe Frage.
                amSchieben: amRegler,
                seitStart: seitStart)

            if auftrag.ladeschirmWeg {
                withAnimation(.easeOut(duration: 0.3)) { schirmWeg = true }
            }
            if auftrag.spurenAnwenden {
                flaeche.wendeSprachenAn(ton: model.tonSprache,
                                        untertitel: model.untertitelSprache,
                                        automatisch: model.untertitelAutomatisch)
            }
            if auftrag.startMelden {
                await model.reportStart(item: titel, plan: plan,
                                        seconds: stand.position)
                zentrale.melden(item: titel, position: stand.position,
                                dauer: stand.dauer, tempo: flaeche.tempo,
                                laeuft: stand.laeuft,
                                sprungweite: (model.zurueckSekunden, model.vorSekunden),
                                bildURL: model.sperrbildURL(for: titel))
            }
            if auftrag.fortschrittMelden {
                await model.reportProgress(item: titel, plan: plan,
                                           seconds: stand.position,
                                           paused: !stand.laeuft)
            }

            // Am Ende von selbst weiter, wenn gewünscht.
            if model.naechsteAutomatisch, let folge = naechsteFolge, !wechselt,
               Folgenende.weiterschalten(position: stand.position, dauer: stand.dauer,
                                         seitOeffnen: Date().timeIntervalSince(seitStart)) {
                zurNaechstenFolge(folge)
            }

            takte += 1
            // Das Now-Playing-Feld braucht die Stelle nur im Sekundentakt.
            if takte % 2 == 0, stand.startGemeldet {
                zentrale.standNachziehen(position: stand.position,
                                         laeuft: stand.laeuft, tempo: flaeche.tempo)
            }
        }
    }

}

// MARK: - Die Videofläche

/// Das Gegenstück zu `VideoSurfaceHost` auf iOS. Dieselbe Aufgabe, nur
/// `NSViewRepresentable` — die Ansicht selbst kommt unverändert aus
/// `Sources/Shared/VLCPlayer.swift`.
struct Videoflaeche: NSViewRepresentable {
    let url: URL
    let startAt: Double
    let container: String?
    /// Solange wahr, ist die Fläche **ausgeblendet** statt überdeckt.
    ///
    /// Das ist der Unterschied zu iOS, und er ist macOS-eigen: VLCs
    /// Videoausgang ist hier ein `VLCOpenGLVideoView`. Eine OpenGL-Ansicht
    /// zeichnet in ihre eigene Fläche und liegt dabei über allem, was im
    /// SwiftUI-Stapel nach ihr kommt — die Reihenfolge im `ZStack` entscheidet
    /// nichts. Ein schwarzer Schleier darüber blieb deshalb wirkungslos, und
    /// man sah VLC an den Anfang gehen und von dort einsteuern.
    ///
    /// `isHidden` wirkt dagegen auf AppKit-Ebene und damit sicher. VLC
    /// dekodiert weiter, nur gezeigt wird nichts.
    let verdeckt: Bool
    let beimAnlegen: (VLCPlayerView) -> Void

    func makeNSView(context: Context) -> VLCPlayerView {
        let ansicht = VLCPlayerView()
        ansicht.isHidden = verdeckt
        ansicht.play(url: url, abSekunden: startAt, container: container)
        DispatchQueue.main.async { beimAnlegen(ansicht) }
        return ansicht
    }

    func updateNSView(_ ansicht: VLCPlayerView, context: Context) {
        if ansicht.isHidden != verdeckt { ansicht.isHidden = verdeckt }
    }

    /// **Fehlte hier, steht auf iOS seit jeher.**
    ///
    /// Ohne das läuft der Wachhund-Zeitgeber der abgeräumten Ansicht endlos
    /// weiter. Auf `stop()` im Verschwinden ist kein Verlass: das trifft die
    /// Ansicht, auf die `flaeche` zeigt, nicht zwingend jede, die SwiftUI
    /// angelegt hat.
    static func dismantleNSView(_ ansicht: VLCPlayerView, coordinator: ()) {
        MainActor.assumeIsolated { ansicht.stop() }
    }
}

// MARK: - Bausteine des Players

struct Sprungknopf: View {
    let symbol: String
    let gross: Bool
    let kuerzel: String
    /// Zählt jeden Druck. Ein **Wert**, kein Schalter: der Effekt spielt bei
    /// jeder Änderung erneut, auch beim zehnten Sprung hintereinander.
    var takt: Int = 0
    /// Der schnelle Austausch statt des vorbeischiebenden.
    var flott = false
    let auswahl: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: auswahl) {
            VStack(spacing: 9) {
                Image(systemName: symbol)
                    // **Ohne das blendet SwiftUI die beiden Symbole
                    // ineinander** — das sieht nach Fehler aus, nicht nach
                    // Absicht. Stand wörtlich so in der iPhone-Fassung; auf
                    // dem Mac fehlte es, und genau das ist das „weniger
                    // smooth" beim Pausieren.
                    //
                    // `.downUp` schiebt beide Symbole aneinander vorbei und
                    // braucht dafür sichtbar Zeit. Für Pause ist das zu lang:
                    // der Knopf muss in demselben Moment umspringen, in dem
                    // der Ton aufhört, sonst wirkt der ganze Player träge.
                    // Dort also der einfache Austausch.
                    .contentTransition(.symbolEffect(flott ? .replace.offUp
                                                           : .replace.downUp))
                    .font(.system(size: gross ? 48 : 30, weight: .regular))
                    .foregroundStyle(Stil.schrift)
                    // Diskreter Effekt aus SF Symbols: spielt einmal ab und
                    // geht von selbst in die Ruhelage zurück. Ein selbst
                    // gerechneter Winkel bliebe stehen.
                    .symbolEffect(.bounce, options: .speed(1.7), value: takt)
                    .frame(width: gross ? 78 : 46, height: gross ? 78 : 46)
                    .scaleEffect(schwebt ? 1.06 : 1)
                Text(verbatim: kuerzel)
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(Stil.schriftSehrLeise)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
        .accessibilityLabel(Text(verbatim: kuerzel))
    }
}

/// Der Zeitregler. Kein `Slider` — der bringt auf dem Mac eine eigene Spur,
/// einen eigenen Griff und ein eigenes Material mit.
struct Zeitregler: View {
    @Binding var position: Double
    let dauer: Double
    /// Solange gezogen wird, übernimmt der Takt VLCs Zeit nicht — sonst
    /// springt der Griff unter dem Zeiger zurück.
    @Binding var amRegler: Bool
    let springe: (Double) -> Void

    @State private var zieht = false
    @State private var zugPosition: Double = 0

    var body: some View {
        GeometryReader { raum in
            let anteil = dauer > 0 ? (zieht ? zugPosition : position) / dauer : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Stil.schrift.opacity(0.18)).frame(height: 4)
                Capsule().fill(Stil.akzent)
                    .frame(width: raum.size.width * min(max(anteil, 0), 1), height: 4)
                Circle()
                    .fill(Stil.schrift)
                    .frame(width: zieht ? 15 : 13, height: zieht ? 15 : 13)
                    .shadow(color: .black.opacity(0.55), radius: 5, y: 1)
                    .offset(x: raum.size.width * min(max(anteil, 0), 1) - 6.5)
            }
            .frame(height: 15)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { wert in
                        zieht = true
                        amRegler = true
                        zugPosition = dauer * min(max(wert.location.x / raum.size.width, 0), 1)
                    }
                    .onEnded { _ in
                        springe(zugPosition)
                        position = zugPosition
                        zieht = false
                        amRegler = false
                    }
            )
        }
        .frame(height: 15)
        // Für VoiceOver ein Regler mit Stelle und Länge, nicht eine
        // namenlose Fläche. Mit den Pfeiltasten lässt sich die Stelle dann
        // auch ohne Ziehen ändern.
        .accessibilityElement()
        .accessibilityLabel("Abspielstelle")
        .accessibilityValue(gesprochen)
        .accessibilityAdjustableAction { richtung in
            let schritt = max(dauer / 20, 10)
            switch richtung {
            case .increment: springe(min(dauer, position + schritt))
            case .decrement: springe(max(0, position - schritt))
            @unknown default: break
            }
        }
    }

    private var gesprochen: String {
        String(localized: "\(Spielzeit.text(position)) von \(Spielzeit.text(dauer))")
    }
}

// MARK: - Das kleine Fenster

/// Der Griff ans Fenster: Vollbild, kleines Fenster, Zeiger.
///
/// Bewusst **dasselbe** Fenster, nur kleiner und über allen anderen: würde der
/// Player in ein zweites Fenster umziehen, müsste VLC seine Zeichenfläche neu
/// bekommen — das hieße Neuaufbau und Sprung an den Anfang.
@MainActor
@Observable
final class Fensterhalter {
    @ObservationIgnored private(set) weak var fenster: NSWindow?

    /// Das Fenster kommt aus `viewDidMoveToWindow` und damit **später** als
    /// `setzePlayer(true)` aus `.onAppear`. Ohne das Nachziehen hier bliebe
    /// die Ampel im Player stehen: `ampelNachziehen` lief ins Leere, weil es
    /// noch kein Fenster gab, und danach rief es niemand mehr.
    func uebernehme(_ neues: NSWindow?) {
        guard fenster !== neues else { return }
        fenster = neues
        vollbildBeobachten()
        ampelNachziehen()
    }

    @ObservationIgnored private var vollbildwache: [NSObjectProtocol] = []

    /// **Beim Wechsel ins Vollbild und zurück neu entscheiden.**
    ///
    /// Im Vollbild lassen wir die Ampel dem System; kommt das Fenster zurück,
    /// muss unsere Regel wieder greifen. Ohne das bliebe sie nach dem
    /// Verlassen des Vollbilds stehen, obwohl die Steuerung längst weg ist.
    private func vollbildBeobachten() {
        vollbildwache.forEach(NotificationCenter.default.removeObserver)
        vollbildwache.removeAll()
        guard let fenster else { return }
        for name: Notification.Name in [NSWindow.didEnterFullScreenNotification,
                                        NSWindow.didExitFullScreenNotification] {
            vollbildwache.append(NotificationCenter.default.addObserver(
                forName: name, object: fenster, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.ampelNachziehen() }
                })
        }
    }
    @ObservationIgnored private var vorher: NSRect?
    private(set) var istKlein = false
    /// Ob der Player gerade das Fenster füllt.
    private(set) var imPlayer = false

    var istVollbild: Bool { fenster?.styleMask.contains(.fullScreen) ?? false }

    /// **Ein Ausdruck, nicht zwei Schalter.**
    ///
    /// Ob der Zeiger im Player oben steht — dort, wo die Ampel sitzt.
    private(set) var zeigerOben = false

    /// Die Ampel verschwindet im kleinen Fenster — dort gehört sie nicht hin
    /// — **und sie geht im Player mit der Steuerung.**
    ///
    /// Paul: „die Ampel sollte natürlich ausblenden, wenn der Player
    /// ausblendet." Genau richtig: sie ist Bedienung, und Bedienung tritt
    /// nach vier Sekunden Ruhe zurück (B1). Ein Film, über dem drei bunte
    /// Punkte kleben, ist kein Vollbild.
    ///
    /// **Im Vollbild fassen wir sie nicht an.** Dort blendet macOS die ganze
    /// Titelleiste samt Ampel von sich aus aus und schiebt sie herunter,
    /// sobald der Zeiger an den oberen Rand geht — so kennt man es vom Mac,
    /// und so soll es bleiben. Griffen wir zusätzlich in die Deckkraft ein,
    /// bliebe die Leiste beim Herunterschieben leer.
    ///
    /// Im Player stand sie früher ebenfalls nicht, mit der Begründung, sie
    /// stünde dann neben dem Winkel, der zurücklegt: zwei Schließer mit
    /// verschiedener Wirkung. Das war meine Entscheidung, nicht Pauls, und
    /// sie war falsch. Ein Fenster ohne Ampel ist auf dem Mac kein Fenster —
    /// man kann es nicht mehr schließen, nicht ablegen, nicht zoomen. Und
    /// das Verstecken hinterliess obendrein einen hellen Streifen, wo die
    /// Knöpfe gesessen hatten.
    ///
    /// Der Winkel bleibt daneben stehen und rückt dafür nach rechts aus:
    /// er schliesst den **Player**, die Ampel das **Fenster**. Zwei
    /// Handlungen, zwei Orte.
    private var ampelSichtbar: Bool {
        if istVollbild { return true }
        return !istKlein && (!imPlayer || zeigerOben)
    }

    private func ampelNachziehen(weich: Bool = false) {
        guard let fenster else { return }
        // **Im Vollbild gar nichts.** Nicht nur „sichtbar lassen", sondern
        // die Knöpfe überhaupt nicht anfassen.
        //
        // Dort schiebt macOS die Titelleiste selbst herunter, sobald der
        // Zeiger an den oberen Rand geht — und animiert dabei genau diese
        // Ansichten. Legt man in demselben Moment eine eigene
        // `NSAnimationContext`-Gruppe auf ihre Deckkraft, ringen zwei
        // Animationen um dieselben Ansichten, und das System steht für einen
        // Moment. Paul: „die ganze App freezed im Fullscreen für so eine
        // Sekunde inkl. dem Rest von Mac."
        //
        // Der erste Anlauf hat nur `Fensteranstrich` im Vollbild ausgesetzt.
        // Das war die halbe Ursache: das Nachziehen der Ampel lief weiter,
        // und es feuerte bei **jeder** Bewegung des Zeigers über die Grenze
        // der oberen Zone.
        guard !istVollbild else { return }
        for knopf in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let ansicht = fenster.standardWindowButton(knopf) else { continue }
            // **Ausblenden, nicht verstecken.** `isHidden` nimmt sie
            // schlagartig weg; die Steuerung daneben blendet über 180 ms.
            // Zwei verschiedene Geschwindigkeiten an derselben Ecke sieht
            // man sofort.
            ansicht.isHidden = false
            if weich {
                NSAnimationContext.runAnimationGroup { lauf in
                    lauf.duration = 0.18
                    lauf.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    ansicht.animator().alphaValue = ampelSichtbar ? 1 : 0
                }
            } else {
                ansicht.alphaValue = ampelSichtbar ? 1 : 0
            }
        }
    }

    /// Der Player meldet, ob der Zeiger oben in der Ampelzone steht.
    func setzeZeigerOben(_ oben: Bool) {
        guard !istVollbild, zeigerOben != oben else { return }
        zeigerOben = oben
        ampelNachziehen(weich: true)
    }

    /// Geht die Steuerung, geht die Ampel in jedem Fall mit — auch wenn der
    /// Zeiger oben stehen bleibt, etwa weil er sich nicht bewegt.
    func setzeSteuerung(_ da: Bool) {
        guard !da, zeigerOben else { return }
        zeigerOben = false
        ampelNachziehen(weich: true)
    }

    /// Der Player meldet sich an und ab.
    func setzePlayer(_ an: Bool) {
        guard imPlayer != an else { return }
        imPlayer = an
        ampelNachziehen()
        // **Nur beim Aufgehen anstreichen, nicht beim Schliessen.**
        //
        // AppKit stellt das Material der Titelleiste bei Gelegenheit wieder
        // her; geht der Player auf, steht es dann als heller Streifen über
        // dem Bild. Deshalb muss der Anstrich dort noch einmal laufen.
        //
        // Beim Schliessen darf er es nicht: `aufraeumen()` hängt an
        // `.onDisappear`, und das feuert, **wenn die Bewegung anfängt** —
        // nicht, wenn sie durch ist. Der Anstrich geht durch den ganzen
        // Ansichtsbaum der Leiste, setzt einen neuen Stilrahmen und blendet
        // Materialflächen aus; das lag damit auf dem Hauptlauf, während die
        // Seite nach unten fuhr. Dieselbe Sorte Fehler wie `stop()` an
        // derselben Stelle, nur zwei Stunden später eingebaut.
        //
        // Nötig ist es beim Schliessen ohnehin nicht: der Anstrich hält, er
        // wurde beim Aufgehen gesetzt.
        if an, let fenster { Fensteranstrich.anstreichen(fenster) }
    }

    func vollbildUmschalten() { fenster?.toggleFullScreen(nil) }

    /// Kleines Fenster an oder aus.
    ///
    /// **Erst aus dem Vollbild.** Dort ignoriert macOS sowohl `setFrame` als
    /// auch den Fensterrang — das kleine Fenster blieb sonst bildschirmfüllend.
    /// Der Rückweg wartet auf die Meldung, dass das Vollbild wirklich verlassen
    /// ist; vorher hat das Fenster noch die alten Maße.
    func setzeKlein(_ klein: Bool) {
        guard let fenster, klein != istKlein else { return }
        istKlein = klein

        if klein, istVollbild {
            var beobachter: NSObjectProtocol?
            beobachter = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: fenster, queue: .main) { [weak self] _ in
                    if let beobachter { NotificationCenter.default.removeObserver(beobachter) }
                    MainActor.assumeIsolated { self?.kleinAnwenden(true) }
                }
            fenster.toggleFullScreen(nil)
            return
        }
        kleinAnwenden(klein)
    }

    private func kleinAnwenden(_ klein: Bool) {
        guard let fenster else { return }

        ampelNachziehen()
        // Ohne Titelleiste zum Anfassen zieht man es am Bild.
        fenster.isMovableByWindowBackground = klein
        fenster.level = klein ? .floating : .normal

        // **Kein `contentAspectRatio`.** Ein gesetztes Verhältnis muss man
        // zum Zurückschalten wieder loswerden, und `.zero` ist dafür kein
        // gültiger Wert — AppKit rechnet damit weiter und stürzt beim Ziehen
        // ab (`_resizeWithEvent:`, brk 1). Gemessen, einmal passiert.
        // Das Bild läuft ohnehin im Letterbox, wenn das Fenster nicht passt.
        if klein {
            vorher = fenster.frame
            fenster.contentMinSize = NSSize(width: 320, height: 180)
            let inhalt = NSRect(origin: .zero, size: NSSize(width: 480, height: 270))
            var rahmen = fenster.frameRect(forContentRect: inhalt)
            if let schirm = fenster.screen?.visibleFrame {
                rahmen.origin = CGPoint(x: schirm.maxX - rahmen.width - 24,
                                        y: schirm.minY + 24)
            }
            fenster.setFrame(rahmen, display: true, animate: true)
        } else {
            fenster.contentMinSize = NSSize(width: Stil.fensterMinBreite,
                                            height: Stil.fensterMinHoehe)
            if let vorher { fenster.setFrame(vorher, display: true, animate: true) }
        }
    }

    /// Beim Verlassen des Players alles zurückdrehen — sonst bliebe das
    /// Hauptfenster ohne Lampen und über allen anderen stehen.
    func aufraeumen() {
        if istKlein { istKlein = false; kleinAnwenden(false) }
        setzePlayer(false)
    }
}

/// Reicht das AppKit-Fenster an den Halter durch.
///
/// **Über `viewDidMoveToWindow`, nicht in `makeNSView`.** Beim Anlegen hängt
/// die View noch in keinem Fenster, `window` ist dort `nil` — und dann lief
/// das kleine Fenster still ins Leere, weil `setzeKlein` am `guard` abbrach.
/// Einmal passiert, und von außen sah es aus, als täte der Knopf nichts.
struct Fensterzugriff: NSViewRepresentable {
    let halter: Fensterhalter

    final class Spion: NSView {
        var gefunden: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            gefunden?(window)
        }
    }

    func makeNSView(context: Context) -> Spion {
        let ansicht = Spion(frame: .zero)
        ansicht.gefunden = { fenster in
            MainActor.assumeIsolated { halter.uebernehme(fenster) }
        }
        return ansicht
    }

    func updateNSView(_ ansicht: Spion, context: Context) {}
}

/// Rückmeldung beim Springen — dieselbe Drehung wie auf den Knöpfen, damit
/// Knopf und Tastendruck nicht wie zwei verschiedene Dinge wirken.
///
/// Wörtlich aus der iPhone-Fassung (`Sprungmarke` in
/// `Sources/iOS/PlayerScreen.swift`), nur ohne den Doppeltipp, den es auf dem
/// Mac nicht gibt. Die Marke steht an derselben Seite, in die gesprungen wird.
private struct Sprungmarke: View {
    let richtung: Int
    let sekunden: Int
    @State private var gedreht = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: richtung < 0 ? "gobackward" : "goforward")
                .font(.system(size: 32, weight: .medium))
                .symbolEffect(.bounce, options: .speed(1.7), value: gedreht)
            Text(verbatim: "\(sekunden) s").font(.footnote.weight(.medium))
        }
        .foregroundStyle(.white)
        .frame(width: 108, height: 108)
        .background(.black.opacity(0.45), in: Circle())
        .onAppear { gedreht = true }
    }
}
