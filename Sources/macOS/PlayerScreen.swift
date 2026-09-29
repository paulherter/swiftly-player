import AppKit
import CoreGraphics
import JellyfinKit
import SwiftUI

/// Der Player im Fenster.
///
/// **Wörtlich die neue Gestaltung von iOS** (`Sources/iOS/PlayerScreen.swift`,
/// `PlayerEbenen.swift`), nur an Maus, Tastatur und Fenster angepasst:
/// - Die Steuerung erscheint, wenn der Zeiger sich bewegt, nicht auf Tippen.
/// - Gespult wird mit den Pfeiltasten, nicht mit Doppeltipp-Dritteln.
/// - Statt Bild-im-Bild gibt es das kleine Fenster (`Fensterhalter`). Das ist
///   keine Wahl, sondern ein Befund: VLC gibt auf macOS keine
///   `AVSampleBufferDisplayLayer` heraus.
/// - Ein eigener Knopf für Vollbild, weil ein Fenster eins kennt und ein
///   Telefon nicht.
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
    /// „Intro überspringen" und „Nächste Folge" über dem Bild, ohne dass die
    /// Steuerung aufgehen muss. Was wann gilt, steht in `Angebotsebene`.
    /// Die Karte der nächsten Folge wartet, solange die Steuerung bewusst
    /// offen ist (Klick ins Bild) — abgebrochen wird am X oder mit Esc
    /// (``Folgenkartenansicht``), wie am iPhone.
    @State private var ebene: Angebotsebene = {
        var e = Angebotsebene()
        e.karteWartetBeiSteuerung = true
        return e
    }()
    /// Spiegelt den Riegel von `folgenwechsel` für die Ansicht.
    @State private var wechselt = false
    @State private var folgenwechsel = Folgenwechsel()
    /// Plan und Dateianfang der nächsten Folge, in den letzten Minuten geholt
    /// — dieselbe Vorbereitung wie am iPhone (``Vorpuffer``).
    @State private var vorbereitung = Folgenvorbereitung()
    /// **Die Karte der nächsten Folge** (``Folgenkarte``, Variante C):
    /// solange sie ins Bild zoomt, gehalten — mit Folge und Countdownstand von
    /// eben, damit nichts blitzt, wenn der Wechsel das Angebot wegnimmt.
    @State private var kartenwechsel: Kartenwechsel?
    @State private var kartenfolge: Item?
    @State private var kartenuhr: Fuellungsuhr?
    @State private var kartenzoom: Double = 0
    @State private var kartenbild: Double = 1
    /// Welcher Titel schon als zu Ende geschaut gezählt ist. `beenden` und
    /// das Verschwinden kommen beide — gezählt wird einmal.
    @State private var gezaehlt: String?
    @State private var hinweis: String?
    /// Der nächste Plan kommt aus einer Qualitätswahl — für den Hinweis.
    @State private var qualitaetGewechselt = false
    @State private var flaeche: VLCPlayerView?
    /// Zaehlt nur, solange das Schild an ist — siehe `Technikschild`.
    @AppStorage("technikschild") private var technikschild = false
    @State private var spielwerte: Spielwerte?
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
    /// Welche der drei Ebenen offen ist — Audio & Untertitel, Folgen,
    /// Einstellungen. `nil` heißt: keine.
    @State private var offeneEbene: Playerebene?
    /// Wo der Zeiger zuletzt stand. Ohne diesen Vergleich stellt jeder
    /// Neuzeichenvorgang den Wecker zurück — und die Schleife zeichnet alle
    /// 500 ms neu, der Wecker läuft also nie ab.
    @State private var zeigerZuletzt: CGPoint?
    /// Nur für die Blende — `stand.erstesBildDa` sagt, *ob*, dieses Merkmal
    /// sorgt dafür, dass das Wegnehmen weich läuft.
    @State private var schirmWeg = false
    /// Wie auf iOS: Sprünge setzen `stand.sprung` über `gesprungen(auf:)`,
    /// und der Takt hält die Zielstelle, bis VLC dort ist (Bug 17.09.2026).
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
    /// Das Bild geht gerade als Karte an ein anderes Gerät.
    @State private var abgabeLaeuft = false
    /// Die Füllung der Karte als durchgehende Bewegung (`Fuellungsuhr`).
    @State private var fuellungsuhr = Fuellungsuhr()
    @State private var halter = Fensterhalter()
    @State private var zentrale = Wiedergabezentrale()
    @State private var ruheAufgabe: Task<Void, Never>?
    /// Je Titel einmal nachsehen, ob der Server Vorschaubilder hat — dasselbe
    /// Paket wie auf iOS (`Sources/Shared/Trickplaybilder.swift`).
    @State private var trickplay = Trickplaybilder()

    /// **Gemeinsam schauen.** Gesetzt beim Öffnen, wenn der Titel der ist,
    /// den die Gruppe schaut. Die Gruppe selbst hält ``Gemeinsammodell``.
    @State private var gemeinsamAn = false
    @State private var bruecke = Gemeinsamspieler()
    private var gemeinsam: Gemeinsammodell { .geteilt }
    /// Läuft dieser Player gerade in einer Gruppe? Dann gehen Anhalten,
    /// Weiter und Springen als Bitte an den Server, nicht an VLC — von
    /// Knöpfen, Leertaste, Pfeiltasten, Medientasten und Fernbefehlen gleich.
    private var inGruppe: Bool { gemeinsamAn && gemeinsam.gruppe != nil }

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

    /// Formatfuellend statt ganzes Bild -- dieselbe Wahl wie die Geste auf
    /// dem iPhone und die Karte am Fernseher, unter demselben Schluessel.
    @AppStorage("bildfuellend") private var bildfuellend = false
    /// Verhindert, dass ein einziges Zusammenziehen mehrfach umschaltet.
    @State private var zoomSchonGeschaltet = false

    private var mass: Playermass { Playermass() }

    var body: some View {
        ZStack {
            Color.black

            Videoflaeche(url: anfang.plan.url, startAt: anfang.startAt,
                         container: anfang.plan.container,
                         verdeckt: !schirmWeg || flaecheAus,
                         puffer: model.pufferstufe,
                         untertitel: model.untertiteldateien(anfang.plan),
                         softwareDekoder: anfang.plan.softwareDekoder,
                         spuren: spurwunsch(titel, anfang.plan)) { neu in
                flaeche = neu
                // Der Knopf hängt an VLCs eigener Meldung, nicht am Takt und
                // nicht am Klick — siehe `laeuftAnzeige`.
                // Dem Server im selben Moment (T1-N1) — `model` hier
                // festgehalten, der Rueckruf lebt laenger als diese Ansicht.
                let melder = model
                neu.laeuftGemeldet = { [weak neu] laeuft in
                    laeuftAnzeige = laeuft
                    melder.laufzustandGemeldet(laeuft: laeuft, sekunden: neu?.positionSeconds ?? 0)
                }
                neu.sprungGemeldet = { ziel in melder.sprungGemeldet(ziel: ziel) }
                neu.spurenGemeldet = { spuren in melder.spurenGewaehlt(spuren) }
                // Was einmal gewaehlt wurde, gilt auch fuer die naechste
                // Folge -- derselbe Schluessel wie die Geste auf dem iPhone
                // und die Karte am Fernseher.
                neu.bildfuellend(bildfuellend)
            }
            .ignoresSafeArea()
            // Ohne das nimmt die Animation der Steuerung die Videofläche mit
            // — sie wuchs bei jedem Einblenden sichtbar von klein auf groß.
            // Eine Narbe der iPhone-Fassung, die mit Bild-im-Bild nichts zu
            // tun hat und uns genauso trifft.
            .transaction { $0.animation = nil }
            // **Zusammenziehen am Trackpad wechselt das Bildformat.**
            //
            // Dasselbe wie die Geste auf dem iPhone, nur mit zwei Fingern auf
            // dem Trackpad; am Fernseher steht dafuer eine Karte im Blatt.
            // Zwei Zustaende -- ganzes Bild mit Balken, oder formatfuellend
            // mit Beschnitt. Ein dritter waere nur eine Streckung.
            //
            // Der Riegel ist noetig, weil `onChanged` waehrend einer Geste
            // dutzendfach feuert: ohne ihn haette ein einziges Auseinander-
            // ziehen zwischen beiden Zustaenden geflackert.
            .simultaneousGesture(
                MagnifyGesture(minimumScaleDelta: 0.05)
                    .onChanged { wert in
                        guard !zoomSchonGeschaltet else { return }
                        if wert.magnification > 1.15, !bildfuellend {
                            zoomSchonGeschaltet = true
                            bildfuellend = true
                            flaeche?.bildfuellend(true)
                        } else if wert.magnification < 0.85, bildfuellend {
                            zoomSchonGeschaltet = true
                            bildfuellend = false
                            flaeche?.bildfuellend(false)
                        }
                    }
                    .onEnded { _ in zoomSchonGeschaltet = false }
            )
            // **Klick ins Bild** holt die Steuerung bewusst — das sagt eine
            // laufende Karte „Nächste Folge" ab, anders als die Zeigerbewegung.
            .simultaneousGesture(TapGesture().onEnded { steuerungZeigen() })

            // **Deckend**, nicht nur ein Rädchen. Vorher stand hier ein
            // durchsichtiger `Lader()`, und das Video lief die ganze Zeit
            // sichtbar darunter — man sah VLC an den Anfang gehen und von
            // dort an die gemerkte Stelle steuern.
            // Zoomt die Karte ins Bild, deckt sie den Wechsel — kein
            // Ladeschirm darüber (wie iOS).
            if !schirmWeg, kartenwechsel == nil { startschleier }
            // Waehrend des Wechsels laeuft die alte Folge weiter; der Ring
            // sagt, dass der Klick angekommen ist.
            if schirmWeg, wechselt, kartenwechsel == nil { Lader() }

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

            // **Was in der Gruppe passiert, kurz oben** — damit niemand
            // rätselt, warum der Film steht.
            if inGruppe, let ereignis = gemeinsam.ereignis {
                Gruppenereignis(symbol: ereignis.symbol, text: ereignis.text)
                    .padding(.top, mass.oben + mass.knopf + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .id(ereignis.id)
                    .zIndex(4)
            }
            // Was bei der Gruppe schiefging — unten über der Leiste.
            Gemeinsamfehler()
                .padding(.bottom, mass.unten + mass.leiste + mass.ueberLeiste)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .zIndex(7)

            if schirmWeg {
                // **Flache Abdunklung, kein Verlauf** — wörtlich `Playerschleier`
                // von iOS (Sources/iOS/PlayerScreen.swift): rgba(11,11,13,.42),
                // ohne Verlauf, wie im Entwurf.
                // Steht die Karte der nächsten Folge, dunkelt er das Bild
                // ebenso ab, und sie liegt davor (wie iOS).
                Stil.grund.opacity(0.42)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .opacity(abgedunkelt ? 1 : 0)
                    .animation(abgedunkelt ? .easeOut(duration: 0.18) : .easeInOut(duration: 0.34),
                               value: abgedunkelt)
            }

            // **Über dem Schleier, unter der Steuerung** — siehe
            // ``Folgenkartenansicht``, warum sie über der Leiste steht.
            kartenebene

            // **Das Technikschild.** Auskunft, kein Bedienteil — es nimmt
            // keine Klicks. **Direkt auf dem Film** (22.09.2026): über
            // der Abdunklung, unter Titel, Knöpfen und Leiste und damit auch
            // unter den Ebenen. **Es gleitet mit der Steuerung** (22.09.2026): offen unter der Titelzeile, zu an den oberen Rand,
            // wo sie stand. Bewegung statt Blende, dieselbe Kurve wie die
            // Steuerung; mit reduzierter Bewegung springt es. Ausserhalb von
            // `schirmWeg`, damit es wie bisher schon beim Laden steht.
            if technikschild {
                Technikschild(plan: plan, werte: spielwerte, flaeche: flaeche)
                    .padding(.leading, mass.seite)
                    .padding(.top, mass.oben + mass.knopf + Stil.kachelAbstand)
                    .offset(y: steuerungDa && offeneEbene == nil ? 0 : -(mass.knopf + Stil.kachelAbstand))
                    .animation(Stil.bewegungReduziert ? nil
                               : steuerungDa ? .easeOut(duration: 0.18) : .easeInOut(duration: 0.34),
                               value: steuerungDa && offeneEbene == nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if schirmWeg {
                Group {
                    mittelsteuerung
                        .opacity(amRegler ? 0 : 1)
                        .allowsHitTesting(!amRegler)
                    VStack(spacing: 0) {
                        kopf
                        Spacer(minLength: 0)
                        fuss
                    }
                }
                .opacity(steuerungDa && offeneEbene == nil ? 1 : 0)
                .allowsHitTesting(steuerungDa && offeneEbene == nil)
                .animation(steuerungDa ? .easeOut(duration: 0.18) : .easeInOut(duration: 0.34),
                           value: steuerungDa)
            }

            // **Die Überspringen-Pille — an derselben Stelle, ob die
            // Steuerung offen ist oder nicht** (wie iOS, 17.09.2026); der
            // Fuß hält ihr nur den Platz frei. Überspringen steht sechs
            // Sekunden von selbst, danach nur mit der Steuerung
            // (`Angebotsebene.knopfdauer`) — auch mit der, die der Zeiger holt.
            //
            // **Weich weg, nicht zack weg** — wie auf dem iPhone (c9298dd5):
            // das Entfernen aus dem Baum lief trotz Transition hart. Die Pille
            // bleibt im Baum, solange es ein Angebot gibt, und kommt und geht
            // über die Deckkraft. `disabled`, damit eine unsichtbare Pille
            // weder Klick noch Tastaturfokus nimmt.
            // Steht dort die Karte der nächsten Folge, weicht die Pille ihr.
            if angebot.sichtbar {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        angebotsknopf
                            .disabled(!knopfDa)
                    }
                }
                .padding(.horizontal, mass.seite)
                .padding(.bottom, mass.unten + mass.leiste + mass.ueberLeiste)
                .opacity(knopfDa ? 1 : 0)
                .allowsHitTesting(knopfDa)
                .accessibilityHidden(!knopfDa)
                .animation(knopfDa ? .easeOut(duration: 0.18) : .easeInOut(duration: 0.34),
                           value: knopfDa)
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18)),
                                        removal: .opacity.animation(.easeInOut(duration: 0.34))))
            }

            if let offeneEbene {
                ebenenansicht(offeneEbene)
                    .transition(.opacity)
                    .zIndex(5)
            }

            stehenderTitel
                .zIndex(6)
        }
        .animation(Stil.einblenden, value: technikschild)
        .animation(Stil.einblenden, value: gemeinsam.ereignis)
        .animation(.easeInOut(duration: 0.2), value: offeneEbene)
        .task(id: technikschild) {
            guard technikschild else { return }
            while !Task.isCancelled {
                // Die Rate entsteht aus der Differenz zum letzten Mal —
                // siehe `Spielwerte`.
                spielwerte = Spielwerte(flaeche?.statistik, stelle: flaeche?.positionSeconds ?? 0,
                                        laeuft: flaeche?.isPlaying ?? false, vorher: spielwerte)
                try? await Task.sleep(for: .seconds(2))
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
            // Nebenbei: Bewegung holt die Steuerung, sagt aber die Karte
            // „Nächste Folge" nicht ab (17.09.2026).
            if weg > 2 { steuerungZeigen(durch: .nebenbei) }
        }
        .onAppear { steuerungZeigen() }
        // Nach dem Schliessen einer Ebene laeuft die Viersekundenuhr neu an.
        .onChange(of: offeneEbene) { _, offen in if offen == nil { steuerungZeigen() } }
        // Die Einblendung hört auf die Steuerung. Nur Abgleich: ob das Öffnen
        // die Karte absagt, entscheidet `steuerungZeigen(durch:)`.
        .onChange(of: steuerungDa, initial: true) { _, offen in
            ebene.steuerung(offen: offen, durch: .nebenbei)
            fuellungStellen()
        }
        .onChange(of: karteDa) { _, da in
            guard kartenwechsel == nil else { return }
            Protokoll.schreib(da ? "[Karte] erscheint bei \(Int(stand.position)) s von \(Int(stand.dauer)) s"
                                 : "[Karte] geht (abgesagt oder Steuerung)")
        }
        .onAppear {
            model.playerOffen = true
            // Vor der Zentrale: deren Griffe fragen die Gruppe.
            if gemeinsam.gehoertZurGruppe(titel.id) {
                brueckeNachziehen()
                gemeinsam.anschliessen(bruecke)
                gemeinsamAn = true
            }
            zentraleUebernehmen()
            // **Auch die Fernsteuerung, nicht nur der Sperrbildschirm.**
            //
            // Beide bekommen dieselben Griffe, sie kommen nur aus
            // verschiedenen Richtungen: die Zentrale von den Medientasten
            // dieses Rechners, `fernbefehl` über Jellyfins Socket von einem
            // anderen Gerät. Auf dem Mac fehlte die zweite Hälfte ganz
            model.fernbefehl = ausfuehren
            halter.setzePlayer(true)
        }
        .onChange(of: stand.laeuft) { _, neu in
            fuellungStellen()
            if laeuftAnzeige == neu { laeuftAnzeige = nil }
        }
        .onChange(of: schlafminuten) { schlafzeitSetzen(schlafminuten) }
        .task {
            let geoeffnet = titel
            // **In der Gruppe keine nächste Folge.** Jeder schaltete sonst für
            // sich weiter, und die Gruppe liefe auseinander.
            await folgenwechsel.nachschlagen(holen: { await model.folgeNach(geoeffnet) },
                                             uebernehmen: { naechsteFolge = gemeinsamAn ? nil : $0 })
            await folgenwechsel.nachschlagen(holen: { await model.abschnitte(fuer: geoeffnet.id) },
                                             uebernehmen: { abschnitte = $0 })
        }
        // Je Titel einmal nachsehen, ob der Server Vorschaubilder hat.
        .task(id: titel.id) { await trickplay.laden(model: model, item: titel, plan: plan) }
        // Das Folgenbild für eine mögliche Übergabe schon bereit — die Karte
        // des Abgebers braucht es im ersten Bild (``Uebergabeabgang``).
        .task(id: titel.id) { await Uebergabeabgang.vorladen(titel, model: model) }
        .onDisappear {
            Uebergabebuehne.geteilt.spielerWeg(titel.id)
            ruheAufgabe?.cancel()
            schlafAufgabe?.cancel()
            halter.aufraeumen()
            zentrale.abgeben()
            model.fernbefehl = nil
            // Schließen heißt verlassen (Entwurf A).
            if gemeinsamAn { gemeinsam.abtrennen() }
            // Ohne `beenden()` zu — Fenster zu, Konto- oder Serverwechsel:
            // ein laufender Wechsel darf danach nichts mehr anwenden, und der
            // Server erfährt das Ende trotzdem (Audit T1-N6). Kam `beenden`
            // vorher, zählt dessen Aufruf; dieser tut dann nichts.
            zaehlen(bei: stand.position)
            folgenwechsel.schliessen(stoppen: stoppMeldung(bei: stand.position))
            // Der Zeiger gehört zurück, sobald der Player weg ist.
            NSCursor.unhide()
            model.playerOffen = false
        }
        .task { await mitlaufen() }
        // Tastenkürzel. Sie stehen zusätzlich in der Menüleiste, damit man sie
        // findet, ohne sie zu kennen.
        .background {
            VStack {
                // **Bei offener Ebene gehoeren die Tasten ihr.**
                //
                // Diese Knoepfe liegen unsichtbar im Hintergrund und galten
                // deshalb immer — auch waehrend eine Ebene offen war. Wer dort
                // durch die Tonspuren ging, hielt mit der Leertaste den Film
                // an und sprang mit den Pfeilen darin herum.
                //
                // Escape bleibt: es schliesst dann die Ebene, nicht den Player
                // — erst die Auswahl zu, dann weggehen.
                Group {
                    Button("") { umschalten() }.keyboardShortcut(.space, modifiers: [])
                    Button("") { springe(-Double(model.zurueckSekunden)) }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Button("") { springe(Double(model.vorSekunden)) }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                }
                .disabled(offeneEbene != nil)
                // **Verzögerung wie in VLC:** G/H Untertitel, J/K Ton, je
                // 50 ms. Nicht bei offener Ebene — dort steht die Zeile
                // selbst, und ihre Anzeige wüsste vom Tastendruck nichts.
                Group {
                    Button("") { verzoegern(untertitel: true, -1) }.keyboardShortcut("g", modifiers: [])
                    Button("") { verzoegern(untertitel: true, 1) }.keyboardShortcut("h", modifiers: [])
                    Button("") { verzoegern(untertitel: false, -1) }.keyboardShortcut("j", modifiers: [])
                    Button("") { verzoegern(untertitel: false, 1) }.keyboardShortcut("k", modifiers: [])
                }
                .disabled(offeneEbene != nil || flaeche == nil)

                Button("") { fluchttaste() }.keyboardShortcut(.escape, modifiers: [])
                // Wie am Fernseher ohne Fokus: steht die Einblendung da, löst
                // die Eingabetaste sie aus (Jellyfin Android TV).
                Button("") { if angebotDa, ebene.anzeige.sichtbar { angebotAusfuehren() } }
                    .keyboardShortcut(.return, modifiers: [])
                // Vollbild auch ohne den Knopf zu treffen — dieselbe Taste,
                // die die Fensterampel dafür anbietet.
                Button("") { halter.vollbildUmschalten() }.keyboardShortcut("f", modifiers: [])
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

    // MARK: - Kopf, Mitte, Fuß

    /// Bei einer Folge die Serie, sonst der Titel selbst — wörtlich die Regel
    /// von iOS.
    private var titelzeile: String {
        if titel.type == "Episode", let serie = titel.seriesName, !serie.isEmpty { return serie }
        return titel.name
    }

    /// „Staffel 1 · Folge 3" — beim Film Jahr, Laufzeit und Genre.
    private var metatext: String? {
        if titel.type == "Episode" {
            if let staffel = titel.parentIndexNumber, let folge = titel.indexNumber {
                return String(localized: "Staffel \(staffel) · Folge \(folge)")
            }
            return titel.kontextzeile
        }
        let zeile = titel.nebenzeile
        return zeile.isEmpty ? nil : zeile
    }

    /// Nur Folgen einer Serie haben eine Folgenliste.
    private var hatFolgen: Bool { titel.type == "Episode" && titel.seriesId != nil }

    /// **Oben links der Titel, oben rechts nur Symbole.** Kein Bild-im-Bild-
    /// Knopf, kein Tempo — beides stand im alten Wiedergabemenü und fällt mit
    /// ihm weg. Beim Spulen weichen die Symbole der Vorschau.
    private var symbolreihe: some View {
        HStack(spacing: 4) {
            Symbolknopf(symbol: "captions.bubble", beschriftung: "Audio & Untertitel",
                        mass: mass) { ebeneOeffnen(.spuren) }
            if hatFolgen {
                Symbolknopf(symbol: "rectangle.stack", beschriftung: "Folgen",
                            mass: mass) { ebeneOeffnen(.folgen) }
            }
            Symbolknopf(symbol: "slider.horizontal.3", beschriftung: "Einstellungen",
                        mass: mass) { ebeneOeffnen(.einstellungen) }
            Symbolknopf(symbol: halter.istVollbild ? "arrow.down.right.and.arrow.up.left"
                                                    : "arrow.up.left.and.arrow.down.right",
                        beschriftung: halter.istVollbild ? "Vollbild verlassen" : "Vollbild",
                        mass: mass) { halter.vollbildUmschalten() }
            Symbolknopf(symbol: "xmark", beschriftung: "Player schließen",
                        mass: mass) { beenden() }
        }
    }

    /// **Der Titel oben links, eine Ebene über allem.** Bei offener
    /// Folgenebene bleibt er genau hier stehen; läge er im Kopf, blendete er
    /// mit der Steuerung aus und in der Ebene wieder ein — er flackerte.
    /// Wörtlich `stehenderTitel` von iOS.
    private var stehenderTitel: some View {
        let da = (steuerungDa && offeneEbene == nil) || offeneEbene == .folgen
        return HStack(alignment: .top, spacing: 12) {
            Text(verbatim: titelzeile)
                .font(.system(size: mass.titel, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
            symbolreihe
                .hidden()
                .accessibilityHidden(true)
        }
        .padding(.horizontal, mass.seite)
        .padding(.top, mass.oben)
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .opacity(da ? 1 : 0)
        .animation(da ? .easeOut(duration: 0.18) : .easeInOut(duration: 0.34), value: da)
    }

    private var kopf: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                // Nur Platzhalter: gezeigt wird der Titel von
                // `stehenderTitel`, der bei offener Folgenebene stehen bleibt.
                Text(verbatim: titelzeile)
                    .font(.system(size: mass.titel, weight: .semibold))
                    .lineLimit(1)
                    .opacity(0)
                    .accessibilityHidden(true)
                HStack(spacing: 6) {
                    // **In der Gruppe steht hier die Gruppe** (Entwurf A):
                    // wo sonst Jahr und Laufzeit stehen. Das ist Zustand,
                    // also Akzent.
                    if inGruppe, let gruppe = gemeinsam.gruppe {
                        Gruppenzeile(name: gruppe.name, mitWem: gemeinsam.mitWem,
                                     groesse: mass.meta)
                    } else if let metatext { Text(verbatim: metatext) }
                    if !plan.isLossless {
                        Label(plan.method.rawValue, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Stil.warnung)
                    }
                }
                .font(.system(size: mass.meta))
                .foregroundStyle(Stil.schriftLeise)
                .lineLimit(1)
            }
            .foregroundStyle(.white)

            Spacer(minLength: 0)

            symbolreihe
                .opacity(amRegler ? 0 : 1)
                .allowsHitTesting(!amRegler)
        }
        .padding(.horizontal, mass.seite)
        .padding(.top, mass.oben)
        .overlay(alignment: .bottom) {
            // Unter der Kopfzeile, mittig: dort kommt sie weder der Leiste
            // noch dem Überspringen-Knopf in die Quere.
            if let hinweis {
                Text(verbatim: hinweis)
                    // `.caption2` sind 11 Regular — 11 steht nur als
                    // Semibold in der Leiter; ein Satz ist eine Angabe,
                    // also 12.
                    .font(Stil.klein).foregroundStyle(Stil.schrift)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, mass.seite)
                    .offset(y: 22)
            }
        }
    }

    private func ebeneOeffnen(_ ziel: Playerebene) {
        offeneEbene = ziel
    }

    private func ebeneSchliessen() {
        offeneEbene = nil
    }

    @ViewBuilder
    private func ebenenansicht(_ welche: Playerebene) -> some View {
        switch welche {
        case .spuren:
            SpurenEbene(flaeche: flaeche, mass: mass, schliessen: ebeneSchliessen)
        case .einstellungen:
            EinstellungsEbene(flaeche: flaeche, mass: mass, schlafminuten: $schlafminuten,
                              qualitaet: qualitaetswahl,
                              gemeinsam: inGruppe ? gemeinsam : nil,
                              gruppeVerlassen: { beenden() },
                              schliessen: ebeneSchliessen)
        case .folgen:
            FolgenEbene(model: model, item: titel, titel: titelzeile, mass: mass,
                        schliessen: ebeneSchliessen) { folge in
                ebeneSchliessen()
                // Die laufende Folge anklicken heißt: weiterschauen.
                guard folge.id != titel.id else { return }
                // In der Gruppe wechselt niemand allein: die Wahl setzt die
                // Warteschlange, und alle laden die Folge (wie iOS).
                if inGruppe { gemeinsam.bitteTitel(folge.id); return }
                zurNaechstenFolge(folge)
            }
        }
    }

    /// Mittig im Bild — die Maus muss dort ohnehin erst hin, anders als der
    /// Daumen, der am Rand liegt.
    private var mittelsteuerung: some View {
        HStack(spacing: 80) {
            Sprungknopf(symbol: "gobackward.\(model.zurueckSekunden)", gross: 30, takt: taktZurueck,
                        beschriftung: "\(model.zurueckSekunden) Sekunden zurück") {
                springe(-Double(model.zurueckSekunden))
            }
            Sprungknopf(symbol: laeuftJetzt ? "pause.fill" : "play.fill", gross: 40, flott: true,
                        beschriftung: laeuftJetzt ? "Anhalten" : "Abspielen") { umschalten() }
            // Vorwärts weiter als rückwärts: vorwärts überspringt man
            // Vorspann und Werbung, rückwärts sucht man einen Satz.
            Sprungknopf(symbol: "goforward.\(model.vorSekunden)", gross: 30, takt: taktVor,
                        beschriftung: "\(model.vorSekunden) Sekunden vor") {
                springe(Double(model.vorSekunden))
            }
        }
    }

    /// Nur die Leiste, über die volle Breite: links die verstrichene Zeit,
    /// rechts die Restzeit.
    private var fuss: some View {
        Zeitzeile(position: $stand.position, dauer: stand.dauer, amRegler: $amRegler,
                  mass: mass, marken: abschnitte.flatMap { [$0.von, $0.bis] },
                  vorschau: { trickplay.bild(bei: $0, model: model) }) { ziel in
            if inGruppe { gemeinsam.bitteSpringen(auf: ziel) }
            else { flaeche?.seek(toSeconds: ziel) }
            gesprungen(auf: ziel)
        }
        .padding(.horizontal, mass.seite)
        .padding(.bottom, mass.unten)
    }

    private var angebotsknopf: some View {
        Angebotsknopf(angebot: angebot, aktion: angebotAusfuehren)
            .accessibilityAction(.escape) { _ = ebene.schliessen() }
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

    private func umschalten() {
        guard let flaeche else { return }
        // In der Gruppe eine Bitte: der Knopf springt erst um, wenn der
        // Befehl zurückkommt — dann bei allen gleichzeitig.
        if inGruppe {
            gemeinsam.bitteUmschalten(laeuftGerade: laeuftJetzt)
            steuerungZeigen()
            return
        }
        if flaeche.isPlaying { flaeche.pause() } else { fortsetzen() }
        steuerungZeigen()
    }

    /// Weiterspielen auf Wunsch des Zuschauers — nach langer Pause ein
    /// Stück zurück (``Pausenruecksprung``), wie am iPhone. Die Zeit
    /// übernimmt das Ziel im selben Moment, damit die Leiste nicht erst die
    /// alte Stelle zeigt. In der Gruppe kommt man hier nicht an: dort ist
    /// Weiterspielen eine Bitte.
    private func fortsetzen() {
        guard let ziel = flaeche?.resume(ruecksprung: !inGruppe) else { return }
        gesprungen(auf: ziel)
    }

    private func springe(_ sekunden: Double) {
        let ziel = Wiedergabetakt.ziel(um: sekunden, stand: stand)
        if inGruppe {
            // Bitte an die Gruppe; gesprungen wird, wenn der Befehl kommt.
            gemeinsam.bitteSpringen(auf: max(0, ziel))
        } else {
            flaeche?.jump(seconds: Int32(sekunden))
        }
        gesprungen(auf: ziel)
        steuerungZeigen()

        if sekunden < 0 { taktZurueck += 1 } else { taktVor += 1 }
        sprungTakt += 1
        let takt = sprungTakt
        // **Mehrfach gedrückt, zählt sie hoch**: +10 s, +20 s, +30 s —
        // solange die Anzeige der vorigen Sprünge in dieselbe Richtung noch
        // steht. Dieselbe Regel wie der Doppeltipp am iPhone, hier für
        // Pfeiltasten und Knöpfe.
        let richtung = sekunden < 0 ? -1 : 1
        let bisher = sprungAnzeige.flatMap { $0.richtung == richtung ? $0.sekunden : nil } ?? 0
        withAnimation(.easeInOut(duration: 0.15)) {
            sprungAnzeige = (richtung, bisher + Int(abs(sekunden)))
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
        if inGruppe {
            switch befehl {
            case .pause:  if laeuftJetzt { gemeinsam.bitteUmschalten(laeuftGerade: true) }
            case .weiter: if !laeuftJetzt { gemeinsam.bitteUmschalten(laeuftGerade: false) }
            case .umschalten: umschalten()
            case .stopp: beenden()
            case let .springenAuf(sekunden):
                gemeinsam.bitteSpringen(auf: sekunden)
                gesprungen(auf: sekunden)
            case .vor:     springe(Double(model.vorSekunden))
            case .zurueck: springe(-Double(model.zurueckSekunden))
            case .naechste, .vorige: break
            }
            steuerungZeigen()
            return
        }
        switch befehl {
        case .pause:     flaeche?.pause()
        case .weiter:    fortsetzen()
        case .umschalten: umschalten()
        // **Ein anderes Gerät übernimmt** (Hinweis kam kurz vorher): das Bild
        // geht als Karte ab. Sonst — Dashboard, andere App — wie immer.
        case .stopp:
            if let ziel = model.uebergabeZielNehmen(), let flaeche { abgeben(an: ziel, flaeche: flaeche) }
            else { beenden() }
        case let .springenAuf(sekunden):
            flaeche?.seek(toSeconds: sekunden)
            gesprungen(auf: sekunden)
        case .vor:       springe(Double(model.vorSekunden))
        case .zurueck:   springe(-Double(model.zurueckSekunden))
        case .naechste:
            if let folge = naechsteFolge { zurNaechstenFolge(folge) }
        case .vorige:    break
        }
        steuerungZeigen()
    }

    /// **Jeder Sprung:** Zeit und Knopf stehen sofort auf dem Ziel, der Takt
    /// übergibt an VLCs Zeit, sobald VLC dort ist (Bug 17.09.2026).
    private func gesprungen(auf ziel: Double) {
        Wiedergabetakt.gesprungen(&stand, ziel: ziel)
        // Ein Sprung in den Abspann oder ans Ende: der Countdown der Karte
        // fängt von vorn an, wie am iPhone (ans Ende gespult, sofort weiter).
        ebene.gesprungen()
        if countdownAnteil != nil { fuellungsuhr = Fuellungsuhr() }
        angebotNachziehen(vergangen: 0)
    }

    /// Die Einblendung an die angezeigte Stelle anpassen — mit `vergangen: 0`
    /// direkt nach einem Sprung, sonst einmal je Takt.
    @discardableResult
    private func angebotNachziehen(vergangen: Double) -> Bool {
        guard !wechselt else { return false }
        var neu = ebene
        let fertig = neu.takt(angebot: angebot,
                          karteFaellig: Abschnittslogik.karteFaellig(position: stand.position,
                                                                     dauer: stand.dauer,
                                                                     abschnitte: abschnitte,
                                                                     hatNaechsteFolge: naechsteFolge != nil,
                                                                     restfenster: Folgenkarte.restfenster),
                          laeuft: stand.laeuft && schirmWeg && !amRegler,
                          vergangen: vergangen,
                          countdown: Abschnittslogik.countdown(position: stand.position, dauer: stand.dauer,
                                                               abschnitte: abschnitte,
                                                               restfenster: Folgenkarte.restfenster),
                          // Am Dateiende zählt der Countdown weiter.
                          amEnde: Folgenende.amEnde(position: stand.position, dauer: stand.dauer)
                              && !amRegler)
        // Blendet der Überspringen-Knopf von selbst aus (`knopfdauer`), soll
        // er so weich gehen, wie er kam: der Takt läuft ohne Animation, also
        // den Wechsel der Sichtbarkeit hier ausdrücklich animieren.
        if neu.anzeige.sichtbar != ebene.anzeige.sichtbar {
            withAnimation(Stil.einblenden) { ebene = neu }
        } else {
            ebene = neu
        }
        fuellungStellen()
        return fertig
    }

    private func fuellungStellen() {
        fuellungsuhr.stellen(anteil: countdownAnteil, laeuft: stand.laeuft && schirmWeg && !amRegler,
                             laenge: ebene.countdownLaenge)
    }

    /// Welcher Knopf gerade gilt. Dieselbe Regel wie auf iOS.
    private var angebot: Knopfangebot {
        guard !wechselt else { return .keiner }
        return Abschnittslogik.angebot(position: stand.position, dauer: stand.dauer,
                                       abschnitte: abschnitte,
                                       hatNaechsteFolge: naechsteFolge != nil)
    }

    /// **Eine Stelle, egal ob die Steuerung offen ist** (wie iOS): solange
    /// der Abschnitt läuft, das Überspringen; bei geschlossener Steuerung die
    /// Karte, bei offener der normale Knopf „Nächste Folge".
    private var angebotDa: Bool {
        guard angebot.sichtbar, schirmWeg, !wechselt, offeneEbene == nil else { return false }
        return ebene.anzeige.sichtbar || (steuerungDa && angebot == .naechsteFolge)
    }

    private var countdownAnteil: Double? {
        if case let .karte(anteil) = ebene.anzeige { return anteil }
        return nil
    }

    /// Die Karte der nächsten Folge steht (oder zoomt gerade).
    private var karteDa: Bool {
        kartenwechsel != nil || (angebotDa && countdownAnteil != nil)
    }

    /// Die Pille unten rechts — nicht, solange dort die Karte steht.
    private var knopfDa: Bool {
        angebotDa && countdownAnteil == nil && kartenwechsel == nil
    }

    /// Der Schleier liegt auf dem Bild: bei offener Steuerung — und solange
    /// die Karte steht, damit sie im Vordergrund liest.
    private var abgedunkelt: Bool {
        (steuerungDa && offeneEbene == nil) || (karteDa && kartenwechsel == nil)
    }

    /// Federn des Entwurfs, kritisch gedämpft (``Folgenkarte``).
    private static func feder(_ omega: Double) -> Animation {
        if Stil.bewegungReduziert { return Stil.blendeReduziert }
        let f = Folgenkarte.feder(omega)
        return .interpolatingSpring(mass: 1, stiffness: f.steifigkeit, damping: f.daempfung)
    }

    /// Die Karte unten rechts — im Baum, solange es eine nächste Folge gibt,
    /// damit Herein und Hinaus Federn aus dem jetzigen Stand sind.
    @ViewBuilder
    private var kartenebene: some View {
        if schirmWeg || kartenwechsel != nil, let folge = kartenfolge ?? naechsteFolge, !inGruppe {
            Folgenkartenansicht(
                folge: folge,
                bildAdresse: model.imageURL(for: folge, maxHeight: 1080)
                    ?? model.querbildURL(for: folge, breite: 1920),
                mass: mass,
                da: karteDa, zoom: kartenzoom,
                angabenDa: karteDa && kartenwechsel == nil,
                bild: kartenbild,
                fuellung: kartenuhr ?? fuellungsuhr,
                rest: ebene.countdownRest,
                tippen: {
                    ebene.gedrueckt()
                    zurNaechstenFolge(folge, ausKarte: true)
                },
                abbrechen: karteAbsagen)
            .allowsHitTesting(karteDa && kartenwechsel == nil)
            .animation(karteDa ? Self.feder(Folgenkarte.erscheinenOmega)
                                .delay(kartenwechsel == nil ? Folgenkarte.erscheinenVerzug : 0)
                               : Self.feder(Folgenkarte.wegOmega),
                       value: karteDa)
        }
    }

    /// Abspann ansehen: Countdown weg, am Dateiende kein Weiterschalten mehr
    /// (`Angebotsebene.weiterAbgesagt`). X an der Karte, Esc, Wegziehen.
    private func karteAbsagen() {
        ebene.schliessen()
        fuellungStellen()
    }

    private func angebotAusfuehren() {
        ebene.gedrueckt()
        switch angebot {
        case .keiner:
            break
        case let .ueberspringen(nach, _):
            if inGruppe { gemeinsam.bitteSpringen(auf: nach) }
            else { flaeche?.seek(toSeconds: nach) }
            gesprungen(auf: nach)
            steuerungZeigen()
        case .naechsteFolge:
            // Aus der Karte (Eingabetaste) zoomt sie ins Bild, aus der Pille
            // der offenen Steuerung nicht.
            if let folge = naechsteFolge { zurNaechstenFolge(folge, ausKarte: karteDa) }
        }
    }

    /// Der Stopp für das, was jetzt läuft — nur, wenn sein Start gemeldet
    /// wurde. Einmal für `beenden` und einmal für das Verschwinden ohne.
    private func stoppMeldung(bei stelle: Double) -> @Sendable () async -> Void {
        let laufend = (item: titel, plan: plan, gemeldet: stand.startGemeldet)
        let model = model
        return {
            guard laufend.gemeldet else { return }
            await model.reportStopped(item: laufend.item, plan: laufend.plan, seconds: stelle)
        }
    }

    /// Zu Ende geschaut? Zählt für Bewertung und Discord-Hinweis
    /// (`AppModel.fertigGeschaut`) — je Titel einmal.
    private func zaehlen(bei stelle: Double) {
        guard gezaehlt != titel.id else { return }
        gezaehlt = titel.id
        model.fertigGeschaut(position: stelle, dauer: stand.dauer)
    }

    /// **Die Wiedergabe geht an ein anderes Gerät** (``Uebergabeabgang``).
    /// Die Stelle geht sofort an den Server — drüben wird auf sie gewartet —,
    /// die Steuerung weg, das Bild steht bei 0,12 s und geht als Karte ab;
    /// danach schließt der Player wie sonst.
    private func abgeben(an ziel: String, flaeche: VLCPlayerView) {
        guard !abgabeLaeuft else { return }
        abgabeLaeuft = true
        let stelle = stand.position
        Task { await stoppMeldung(bei: stelle)() }
        var ohne = Transaction()
        ohne.disablesAnimations = true
        withTransaction(ohne) { steuerungDa = false }
        Uebergabeabgang.starten(flaeche: flaeche, ziel: ziel, titel: titel, model: model,
                                anhalten: { flaeche.pause() },
                                fertig: { beenden() })
    }

    private func beenden() {
        // **Vor** dem Anhalten ablesen — danach steht die Zeit auf null und
        // „Weiterschauen" verlöre die Stelle.
        let stelle = stand.position
        zaehlen(bei: stelle)

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

        // Ueber den Wechsel: laeuft gerade einer, bricht er ab, und ist der
        // Start der neuen Folge unterwegs, geht der Stopp danach.
        folgenwechsel.schliessen(stoppen: stoppMeldung(bei: stelle))
        schliessen()
        // Abgeräumt wird in `Videoflaeche.dismantleNSView`, also dann, wenn
        // SwiftUI die Ansicht wirklich entfernt — nach der Bewegung. Ein
        // eigener Wecker dafür war geraten und traf den Zeitpunkt nur
        // ungefähr.
    }

    /// Esc verlässt zuerst eine offene Ebene, dann das Vollbild, und schließt
    /// erst dann den Film. Andersherum verliert man beim Versuch, aus dem
    /// Vollbild zu kommen, die Wiedergabe — und das ist keine Kleinigkeit,
    /// wenn man mitten drin ist.
    private func fluchttaste() {
        // **Erst die Auswahl, dann der Player.** Zurueck heisst zuerst
        // „diese Ebene geht zu" — dieselbe Regel wie auf iOS und dem
        // Fernseher.
        if offeneEbene != nil {
            ebeneSchliessen()
            return
        }
        // Dann die Einblendung — der Film läuft weiter.
        if angebotDa, ebene.anzeige.sichtbar {
            ebene.schliessen()
            fuellungStellen()
            return
        }
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
        // Auch hier: eine offene Ebene bleibt. Den Zeiger aus dem Fenster
        // zu schieben ist kein Grund, eine Entscheidung abzuraeumen, die
        // gerade getroffen wird.
        guard offeneEbene == nil else { return }
        ruheAufgabe?.cancel()
        withAnimation(.easeInOut(duration: 0.34)) {
            steuerungDa = false
            halter.setzeSteuerung(false)
        }
    }

    /// `.bewusst` (Klick, Taste, Knopf) sagt eine laufende Karte „Nächste
    /// Folge" ab, `.nebenbei` (Zeigerbewegung) nicht.
    private func steuerungZeigen(durch art: Angebotsebene.Oeffnung = .bewusst) {
        withAnimation(.easeOut(duration: 0.18)) { steuerungDa = true }
        ebene.steuerung(offen: true, durch: art)
        fuellungStellen()
        halter.setzeSteuerung(true)
        NSCursor.unhide()
        ruheAufgabe?.cancel()
        ruheAufgabe = Task {
            try? await Task.sleep(for: .seconds(4))
            // **Solange eine Ebene offen ist, wird nichts weggenommen.**
            //
            // Sie stand mit im Ausblenden -- wer die Einstellungen oeffnete
            // und die Maus liegen liess, sah nach vier Sekunden alles
            // verschwinden, die Auswahl eingeschlossen. Eine offene Ebene
            // ist Aufmerksamkeit; sie zaehlt wie eine Hand am Regler.
            //
            // Die Uhr faengt nach dem Schliessen von vorn an, siehe unten --
            // dieser Riegel sitzt nach dem Schlafen, die Aufgabe endet hier
            // also, ohne eine neue anzustossen.
            guard !Task.isCancelled, stand.laeuft, !amRegler, offeneEbene == nil else { return }
            withAnimation(.easeInOut(duration: 0.34)) {
                steuerungDa = false
                halter.setzeSteuerung(false)
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
        // In der Gruppe gehen die Medientasten als Bitte — gefragt wird beim
        // Druck, nicht beim Anlegen der Griffe.
        zentrale.uebernehmen(.init(
            abspielen: { if inGruppe { gemeinsam.bitteUmschalten(laeuftGerade: false) }
                         else { fortsetzen() } },
            anhalten:  { if inGruppe { gemeinsam.bitteUmschalten(laeuftGerade: true) }
                         else { flaeche?.pause() } },
            umschalten: { umschalten() },
            springenAuf: { ziel in
                if inGruppe { gemeinsam.bitteSpringen(auf: ziel); gesprungen(auf: ziel) }
                else { flaeche?.seek(toSeconds: ziel); gesprungen(auf: ziel) } },
            vor:     { springe(Double(model.vorSekunden)) },
            zurueck: { springe(-Double(model.zurueckSekunden)) },
            naechste: inGruppe ? nil : naechsteFolge.map { folge in { zurNaechstenFolge(folge) } }))
    }

    /// Wechselt im laufenden Player, ohne in die Übersicht zurückzuspringen.
    ///
    /// **Der Ablauf steht im Paket** (`Folgenwechsel`), gemeinsam mit iOS und
    /// tvOS. Hier setzte der Wechsel den Stand erst nach `await reportStart`
    /// zurück; fiel ein Meldetakt dazwischen, bekam die **neue** Folge die
    /// Stelle der alten als Fortsetzstelle (Audit 16.09.2026, T1-M2), und der
    /// Ladeschirm kam nicht zurück (T1-M3).
    /// Direct Play oder Obergrenze — nur, wenn vom Server gespielt wird und
    /// das Konto umwandeln darf.
    private var qualitaetswahl: Qualitaetswahl? {
        // **In der Gruppe keine Wahl** (wie iOS): der Wechsel lud den Titel
        // an der Gruppe vorbei neu, danach lief man allein weiter.
        guard model.downloads.datei(fuer: titel.id) == nil, model.umwandelnErlaubt,
              !inGruppe else { return nil }
        return Qualitaetswahl(directPlay: model.immerDirectPlay, grenze: model.bitratenGrenze) { wert in
            // Die Gruppe kann dazukommen, während die Ebene offen steht.
            guard !inGruppe else { return }
            let vorher = (model.immerDirectPlay, model.bitratenGrenze)
            if let wert {
                model.immerDirectPlay = false
                model.bitratenGrenze = wert
            } else {
                model.immerDirectPlay = true
            }
            guard vorher != (model.immerDirectPlay, model.bitratenGrenze) else { return }
            Protokoll.schreib("[Qualität] \(model.immerDirectPlay ? "Direct Play" : "\(model.bitratenGrenze) Mbit/s") — neu laden bei \(Int(stand.position)) s")
            let stelle = stand.position
            ebeneSchliessen()
            // Ein vorbereiteter Plan der nächsten Folge trägt die alte Wahl.
            vorbereitung.vergessen()
            qualitaetGewechselt = true
            zurNaechstenFolge(titel, ab: stelle)
        }
    }

    private func zurNaechstenFolge(_ folge: Item, ab: Double = 0, ausKarte: Bool = false) {
        guard !wechselt else { return }
        wechselt = true
        // **Aus der Karte: sie zoomt aufs ganze Bild** und deckt den Wechsel
        // (wie iOS). Nicht in der Gruppe, nicht bei derselben Folge
        // (Qualitätswahl).
        let zoomt = ausKarte && !inGruppe && folge.id != titel.id
        if zoomt {
            kartenfolge = folge
            kartenuhr = fuellungsuhr
            kartenwechsel = Kartenwechsel(folgeID: folge.id)
            Protokoll.schreib("[Karte] Start → \(folge.id)")
            withAnimation(Self.feder(Folgenkarte.zoomOmega)) { kartenzoom = 1 }
            if let beginn = kartenwechsel?.beginn { Task { await karteWachen(beginn) } }
        }
        let tauschAb = zoomt ? Date().addingTimeInterval(Folgenkarte.tausch) : nil
        zaehlen(bei: stand.position)
        let alt = (item: titel, plan: plan, stelle: stand.position)
        // In den letzten Minuten schon geholt (``Folgenvorbereitung``)? Dann
        // wartet der Wechsel nicht noch einmal auf den Server.
        let vorbereitet = vorbereitung.nimm(folge.id)
        Protokoll.schreib("[Wechsel] Beginn → \(folge.id) · Plan vorbereitet: \(vorbereitet != nil ? "ja" : "nein")")
        Task {
            let ergebnis = await folgenwechsel.ausfuehren(.init(
                stoppen: { await model.reportStopped(item: alt.item, plan: alt.plan,
                                                     seconds: alt.stelle) },
                planen: {
                    let neuerPlan: PlaybackPlan?
                    if let vorbereitet { neuerPlan = vorbereitet }
                    else { neuerPlan = await model.plan(for: folge.id) }
                    // Erst tauschen, wenn die Karte das Bild deckt — sonst
                    // stünde um sie herum Schwarz.
                    if let tauschAb, neuerPlan != nil {
                        let rest = tauschAb.timeIntervalSinceNow
                        if rest > 0 { try? await Task.sleep(for: .seconds(rest)) }
                    }
                    return neuerPlan
                },
                anwenden: { neuerPlan in folgeAnwenden(folge, neuerPlan, ab: ab) },
                starten: { neuerPlan in await model.reportStart(item: folge, plan: neuerPlan,
                                                           seconds: ab) },
                gescheitert: {
                    melde(String(localized: "Nächste Folge konnte nicht geladen werden."))
                    // Die alte Folge laeuft weiter, der Server kennt sie aber
                    // schon als beendet. Die Schleife meldet sie neu an.
                    stand.startGemeldet = false
                }))
            Protokoll.schreib("[Wechsel] \(ergebnis) → \(folge.id)")
            // **Hier ist der Wechsel fertig, also faellt hier der Riegel** —
            // nicht erst nach dem Nachschlag. Solange er liegt, gibt es keine
            // Knoepfe; eine gute Minute ohne Knoepfe fuehlt sich tot an.
            wechselt = false
            guard ergebnis == .gewechselt else {
                if kartenwechsel != nil { karteZurueck() }
                return
            }
            await folgenwechsel.nachschlagen(holen: { await model.folgeNach(folge) },
                                             uebernehmen: { naechsteFolge = gemeinsamAn ? nil : $0 })
            await folgenwechsel.nachschlagen(holen: { await model.abschnitte(fuer: folge.id) },
                                             uebernehmen: { abschnitte = $0 })
            // **Bleibt hinten.** Die Zentrale traegt den Befehl „naechste
            // Folge", und der braucht `naechsteFolge`.
            zentraleUebernehmen()
        }
    }

    /// Das erste Bild der neuen Folge steht: das Vorschaubild blendet aus,
    /// darunter läuft sie schon — frühestens ab dem Tausch.
    private func karteUebergeben() async {
        guard let k = kartenwechsel, let bildSeit = k.bildSeit else { return }
        let warten = Folgenkarte.blendeAb(bildSeit: bildSeit) - k.seit
        if warten > 0 { try? await Task.sleep(for: .seconds(warten)) }
        withAnimation(Stil.bewegungReduziert ? Stil.blendeReduziert
                      : .easeInOut(duration: Folgenkarte.bildBlende)) { kartenbild = 0 }
        try? await Task.sleep(for: .seconds(Folgenkarte.bildBlende))
        guard kartenwechsel?.beginn == k.beginn else { return }
        Protokoll.schreib("[Karte] Ende nach \(Int(k.seit * 1000)) ms")
        karteAufraeumen()
    }

    /// Der Wechsel scheiterte: die Karte geht zurück in die Ecke und hinaus.
    private func karteZurueck() {
        Protokoll.schreib("[Karte] Wechsel gescheitert, zurück")
        withAnimation(Self.feder(Folgenkarte.wegOmega)) { kartenzoom = 0 }
        karteAufraeumen()
    }

    /// **Ohne erstes Bild weicht die Karte dem Ladeschirm.** Solange sie
    /// gezoomt liegt, gibt es weder Steuerung noch Ladeschirm und damit
    /// keinen Weg hinaus; kommt das Bild nicht (``Folgenkarte/weicht``),
    /// übernimmt der gewöhnliche Ladeschirm samt Schließen. Der Wechsel
    /// läuft darunter weiter.
    private func karteWachen(_ beginn: Date) async {
        try? await Task.sleep(for: .seconds(Folgenkarte.hoechstensDecken))
        guard let k = kartenwechsel, k.beginn == beginn,
              Folgenkarte.weicht(seit: k.seit, bildSeit: k.bildSeit) else { return }
        Protokoll.schreib("[Karte] kein Bild nach \(Int(k.seit * 1000)) ms, Ladeschirm übernimmt")
        karteAufraeumen()
    }

    private func karteAufraeumen() {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            kartenwechsel = nil
            kartenfolge = nil
            kartenuhr = nil
            kartenzoom = 0
            kartenbild = 1
        }
    }

    /// Die neue Folge übernehmen — **vor** `play` und vor jedem `await`.
    /// Die Spurwahl fürs Öffnen — dieselben Eingaben wie `wendeSprachenAn`,
    /// nur schon vor `play`, damit VLC gleich mit der richtigen Spur anläuft.
    private func spurwunsch(_ titel: Item, _ plan: PlaybackPlan) -> VLCPlayerView.Spurwunsch {
        VLCPlayerView.Spurwunsch(ton: model.tonSprache, untertitel: model.untertitelSprache,
                                 automatisch: model.untertitelAutomatisch, quelle: plan.quelle,
                                 titel: Spurgedaechtnis.titel(fuer: titel))
    }

    private func folgeAnwenden(_ folge: Item, _ neuerPlan: PlaybackPlan, ab: Double = 0) {
        if let kartenwechsel {
            Protokoll.schreib("[Karte] Tausch nach \(Int(kartenwechsel.seit * 1000)) ms")
        }
        // Verzögerung: dieselbe Serie behält sie, sonst null.
        flaeche?.verzoegerungFuerNeuenTitel(alterTitel: titel.id, alteSerie: titel.seriesId,
                                            neuerTitel: folge.id, neueSerie: folge.seriesId)
        titel = folge
        plan = neuerPlan
        // Grenze gewählt, aber es läuft das Original: entweder reicht die Datei
        // schon, oder der Server wandelt nicht um. Sagen statt schweigen.
        if qualitaetGewechselt {
            qualitaetGewechselt = false
            if !model.immerDirectPlay, neuerPlan.method == .directPlay {
                melde(String(localized: "Läuft in Originalqualität. Der Server wandelt nichts um."))
            }
        }
        // Stelle, Spuren, Startmeldung und erstes Bild zurueck; `true`, weil
        // der Wechsel den Start meldet.
        Wiedergabetakt.neuerTitel(&stand, startGemeldet: true)
        // **Mitten in der Folge anfangen ist ein Sprung** — wie auf iOS.
        if ab > 0 { gesprungen(auf: ab) }
        // Der Ladeschirm kommt zurueck, bis VLC die neue Folge zeigt.
        schirmWeg = false
        // **Auch die Uhr.** Ohne das hält `Zeitannahme` die neue Folge für
        // einen alten, längst eingesteuerten Titel. Auf tvOS hat genau das
        // eine Folge übersprungen. (`zentraleUebernehmen` setzt sie ebenfalls.)
        seitStart = Date()
        // **Nichts zeigt mehr auf die alte Folge** (T1-M4).
        naechsteFolge = nil
        abschnitte = []
        ebene.neueFolge()
        zentraleUebernehmen()
        // **Auch hier vor `play`.** Ohne das behielte die nächste Folge die
        // Pufferstufe vom Öffnen.
        flaeche?.puffer = model.pufferstufe
        flaeche?.spurwunsch = spurwunsch(folge, neuerPlan)
        flaeche?.play(url: neuerPlan.url, abSekunden: ab, container: neuerPlan.container,
                      untertitel: model.untertiteldateien(neuerPlan),
                      softwareDekoder: neuerPlan.softwareDekoder)
    }

    /// Tastenkürzel G/H/J/K: einen Schritt schieben und den neuen Wert sagen.
    private func verzoegern(untertitel: Bool, _ richtung: Int) {
        guard let flaeche else { return }
        if untertitel {
            flaeche.untertitelVerzoegerung = flaeche.untertitelVerzoegerung.verschoben(richtung)
            melde(String(localized: "Untertitelverzögerung \(flaeche.untertitelVerzoegerung.text())"))
        } else {
            flaeche.tonVerzoegerung = flaeche.tonVerzoegerung.verschoben(richtung)
            melde(String(localized: "Tonverzögerung \(flaeche.tonVerzoegerung.text())"))
        }
    }

    /// Trägt den jetzigen Stand in die Brücke zur Gruppe und gibt ihr den
    /// Takt — siehe ``Gemeinsamspieler``, warum ein Objekt und kein Abschluss.
    private func brueckeNachziehen() {
        bruecke.flaeche = flaeche
        bruecke.titelID = titel.id
        bruecke.istBereit = (flaeche?.startFertig ?? false) && schirmWeg && !wechselt
        bruecke.sprungZeigen = { ziel in gesprungen(auf: ziel) }
        bruecke.titelWechseln = { folge, _, ab in zurNaechstenFolge(folge, ab: ab) }
        gemeinsam.spielertakt()
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
        var nurZeit = false
        while !Task.isCancelled {
            try? await Task.sleep(for: Wiedergabetakt.anzeigetakt)
            guard let flaeche else { continue }
            if gemeinsamAn { brueckeNachziehen() }

            // **Dazwischen nur die Zeit**, wie auf iOS (17.09.2026): im
            // halben Sekundentakt lief sie verzögert an und zählte ungleichmäßig.
            nurZeit.toggle()
            if nurZeit {
                if !wechselt {
                    Wiedergabetakt.zeitUebernehmen(&stand, gemeldet: flaeche.positionSeconds,
                                                   amSchieben: amRegler, seitStart: seitStart)
                }
                continue
            }

            // Ob VLC am Ziel eines Sprungs steht, entscheidet `Wiedergabetakt`
            // anhand von `stand.sprung` (Bug 17.09.2026).

            let auftrag = Wiedergabetakt.rechnen(
                &stand,
                messung: .init(dauer: flaeche.durationSeconds,
                               position: flaeche.positionSeconds,
                               guteStelle: flaeche.guteStelle,
                               zeigtBild: flaeche.zeigtBild,
                               stelltEin: flaeche.stelltEin,
                               laeuft: flaeche.isPlaying,
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
                               hatTonspuren: stand.spurenGesetzt || !flaeche.tonspuren.isEmpty),
                stelltWiederHer: false,
                // Kein Finger, aber ein Zeiger — dieselbe Frage.
                amSchieben: amRegler,
                seitStart: seitStart)

            if auftrag.ladeschirmWeg {
                Startmessung.geteilt.marke("Ladeschirm weicht")
                // Zoomt die Karte gerade ins Bild, übergibt sie jetzt an die
                // neue Folge (wie iOS).
                if let k = kartenwechsel, k.bildSeit == nil {
                    kartenwechsel?.bildSeit = k.seit
                    Protokoll.schreib("[Karte] erstes Bild nach \(Int(k.seit * 1000)) ms")
                    Task { await karteUebergeben() }
                }
                withAnimation(.easeOut(duration: 0.3)) { schirmWeg = true } completion: {
                    Startmessung.geteilt.marke("Ladeschirm ausgeblendet")
                }
                // Aus einer Übergabe: die Karte zoomt jetzt aufs Bild.
                Uebergabebuehne.geteilt.bildDa(titel.id)
            }
            if auftrag.spurenAnwenden {
                flaeche.wendeSprachenAn(ton: model.tonSprache,
                                        untertitel: model.untertitelSprache,
                                        automatisch: model.untertitelAutomatisch,
                                        quelle: plan.quelle,
                                        titel: Spurgedaechtnis.titel(fuer: titel))
            }
            // Waehrend des Wechsels schweigen, wie auf iOS (T1-M2).
            // Abgesetzt, nicht abgewartet (T1-H2) — siehe tvOS.
            if auftrag.startMelden, !wechselt {
                model.reportStart(item: titel, plan: plan,
                                  seconds: stand.position)
                zentrale.melden(item: titel, position: stand.position,
                                dauer: stand.dauer, tempo: flaeche.tempo,
                                laeuft: stand.laeuft,
                                sprungweite: (model.zurueckSekunden, model.vorSekunden),
                                bildURL: model.sperrbildURL(for: titel))
            }
            if auftrag.fortschrittMelden, !wechselt {
                model.reportProgress(item: titel, plan: plan,
                                     seconds: stand.position,
                                     paused: !stand.laeuft)
            }

            // **Die Einblendung** (Countdown der Karte). Im Stehen hält er an.
            let karteVorher = karteDa
            if angebotNachziehen(vergangen: Wiedergabetakt.taktlaenge / .seconds(1)),
               let folge = naechsteFolge {
                Protokoll.schreib("[Karte] Countdown abgelaufen")
                zurNaechstenFolge(folge, ausKarte: karteVorher)
            }

            // **Die nächste Folge vorbereiten**, solange diese noch läuft —
            // nicht in der Gruppe, die schaltet selbst. Einmal je Folge;
            // wann und über welches Netz, sagt `Vorpuffer`.
            if let folge = naechsteFolge, !inGruppe, !wechselt,
               Vorpuffer.jetzt(position: stand.position, dauer: stand.dauer,
                               abspannVon: abschnitte.first { $0.art == .abspann }?.von,
                               netzGuenstig: vorbereitung.netzGuenstig) {
                vorbereitung.vorbereiten(folge) { await model.plan(for: folge.id, still: true) }
            }

            // Am Ende von selbst weiter — nur mit Karte (Abspann-Abschnitt vom
            // Server), nicht, wenn sie abgesagt wurde (17.09.2026). **Zählt
            // die Karte, gehört das Weiterschalten ihr** (wie iOS: ans Ende
            // gespult, und das Dateiende wechselte sofort).
            if ebene.weiterAmEnde, let folge = naechsteFolge, !wechselt,
               Folgenende.weiterschalten(position: stand.position, dauer: stand.dauer,
                                         seitOeffnen: Date().timeIntervalSince(seitStart),
                                         karteZaehlt: ebene.karteZaehlt) {
                Protokoll.schreib("[Wechsel] Dateiende ohne Karte")
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
    /// **Vor `play`, nicht danach.** Der Vorrat wird als Option an das Medium
    /// gehängt; wer ihn nachträgt, hat schon mit der alten Stufe geöffnet.
    let puffer: Pufferstufe
    /// Externe Untertitel, ebenfalls vor `play` (T1-H4).
    var untertitel: [Untertiteldatei] = []
    /// Gleich mit Software-Dekoder öffnen — ``PlaybackPlan/softwareDekoder``.
    var softwareDekoder = false
    /// Die gewünschten Spuren, ebenfalls vor `play`.
    var spuren: VLCPlayerView.Spurwunsch?
    let beimAnlegen: (VLCPlayerView) -> Void

    func makeNSView(context: Context) -> VLCPlayerView {
        let ansicht = VLCPlayerView()
        ansicht.isHidden = verdeckt
        ansicht.puffer = puffer
        ansicht.spurwunsch = spuren
        ansicht.play(url: url, abSekunden: startAt, container: container, untertitel: untertitel,
                     softwareDekoder: softwareDekoder)
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

/// Runder Knopf in der Mitte — −10, Pause/Play, +10. Anders als die alte
/// Fassung ohne Kürzel-Beschriftung darunter: wörtlich das Bild von iOS, das
/// keine Tastaturhinweise im Player zeigt.
struct Sprungknopf: View {
    let symbol: String
    /// Kantenlänge des Symbols selbst — 30 für ±10, 40 für Play/Pause.
    let gross: CGFloat
    /// Zählt jeden Druck. Ein **Wert**, kein Schalter: der Effekt spielt bei
    /// jeder Änderung erneut, auch beim zehnten Sprung hintereinander.
    var takt: Int = 0
    /// Der schnelle Austausch statt des vorbeischiebenden.
    var flott = false
    let beschriftung: LocalizedStringKey
    let aktion: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: aktion) {
            Image(systemName: symbol)
                // **Ohne das blendet SwiftUI die beiden Symbole
                // ineinander** — das sieht nach Fehler aus, nicht nach
                // Absicht.
                //
                // `.downUp` schiebt beide Symbole aneinander vorbei und
                // braucht dafür sichtbar Zeit. Für Pause ist das zu lang:
                // der Knopf muss in demselben Moment umspringen, in dem
                // der Ton aufhört, sonst wirkt der ganze Player träge.
                // Dort also der einfache Austausch.
                .contentTransition(.symbolEffect(flott ? .replace.offUp
                                                       : .replace.downUp))
                .font(.system(size: gross, weight: .medium))
                .foregroundStyle(Stil.schrift)
                // Diskreter Effekt aus SF Symbols: spielt einmal ab und
                // geht von selbst in die Ruhelage zurück.
                // Kein Huepfen bei reduzierter Bewegung — daneben wird die
                // Einstellung fuer den Massstab schon abgefragt.
                .symbolEffect(.bounce, options: .speed(1.7),
                              value: Stil.bewegungReduziert ? 0 : takt)
                .frame(width: gross * 1.8, height: gross * 1.8)
                .scaleEffect(schwebt ? 1.06 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckknopf())
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
        .accessibilityLabel(Text(beschriftung))
    }
}

/// Zeit links, Regler, Restzeit rechts.
private struct Zeitzeile: View {
    @Binding var position: Double
    let dauer: Double
    @Binding var amRegler: Bool
    let mass: Playermass
    /// Vorspann, Rückblick, Abspann — Anfang und Ende als Kerben.
    let marken: [Double]
    /// Das Trickplay-Bild zur Stelle, oder `nil`.
    let vorschau: (Double) -> CGImage?
    /// Beim Loslassen: wohin gesprungen wird.
    let springe: (Double) -> Void

    /// **Restzeit oder Ende — ein Klick schaltet um**, wie der Tipp am
    /// iPhone: „−12:34" oder „Endet um 22:41"; die Wahl bleibt, unter
    /// demselben Schlüssel. Kein eigener Knopf, keine zweite Zeile.
    @AppStorage("restzeitAlsEnde") private var alsEnde = false

    var body: some View {
        HStack(spacing: 14) {
            Text(Spielzeit.text(position))
            Zeitregler(position: $position, dauer: dauer, amRegler: $amRegler, mass: mass,
                       marken: marken, vorschau: vorschau, springe: springe)
            restzeit
        }
        .font(.system(size: mass.zeit).monospacedDigit())
        .foregroundStyle(Stil.schriftLeise)
    }

    private var ende: Text {
        let rest = max(dauer - position, 0)
        return Text("Endet um \(Date().addingTimeInterval(rest).formatted(date: .omitted, time: .shortened))")
    }

    private var restzeit: some View {
        Button {
            alsEnde.toggle()
        } label: {
            Group {
                if alsEnde { ende } else { Text(verbatim: "−" + Spielzeit.text(max(dauer - position, 0))) }
            }
            .lineLimit(1)
            .contentShape(Rectangle().inset(by: -8))
        }
        .buttonStyle(.plain)
        .help(Text("Wechselt zwischen Restzeit und Ende"))
        .accessibilityLabel(alsEnde ? ende : Text("Restzeit"))
        .accessibilityHint(Text("Wechselt zwischen Restzeit und Ende"))
    }
}

/// Der Zeitregler: 4-pt-Balken, beim Ziehen 6 pt mit Akzent-Griff — wörtlich
/// dieselbe Regel wie auf iOS (`Zeitregler` in `Sources/Shared/Stil.swift`).
///
/// **Anders als dort: die Vorschau erscheint schon beim blossen Überfahren
/// mit der Maus**, nicht erst beim Ziehen — eine Maus kann hovern, ein Finger
/// nicht, und genau darauf soll sie antworten (Auftrag, 19.09.2026). Der
/// Balken selbst bleibt dabei ruhig; nur die Vorschau über dem Zeiger folgt.
private struct Zeitregler: View {
    @Binding var position: Double
    let dauer: Double
    @Binding var amRegler: Bool
    let mass: Playermass
    /// Abschnittsgrenzen in Sekunden — als Kerben gezeichnet, und beim Ziehen
    /// rastet der Griff an ihnen ein (``Kerbenfang``).
    let marken: [Double]
    let vorschau: (Double) -> CGImage?
    let springe: (Double) -> Void

    @State private var zieht = false
    /// Die Kerbe, auf der der Griff gerade eingerastet steht — damit der
    /// Tick einmal beim Einrasten kommt, nicht bei jeder Bewegung darauf.
    @State private var eingerastet: Double?

    /// Die Grenzen als Anteil, ohne die an den beiden Kanten — wie am iPhone.
    private var kerben: [CGFloat] {
        guard dauer > 0 else { return [] }
        return marken.map { CGFloat($0 / dauer) }.filter { $0 > 0.01 && $0 < 0.99 }
    }
    @State private var zugAnteil: CGFloat = 0
    /// Anteil unter dem Zeiger, unabhängig vom Ziehen — `nil`, solange der
    /// Zeiger nicht über der Leiste steht.
    @State private var hoverAnteil: CGFloat?

    private var anzeigeAnteil: CGFloat {
        zieht ? zugAnteil : (dauer > 0 ? CGFloat(min(max(position / dauer, 0), 1)) : 0)
    }

    /// Welcher Anteil gerade eine Vorschau zeigt: beim Ziehen der Griff,
    /// sonst der Zeiger.
    private var schauAnteil: CGFloat? { zieht ? zugAnteil : hoverAnteil }

    var body: some View {
        GeometryReader { raum in
            let dicke: CGFloat = zieht ? 6 : 4
            let anteil = anzeigeAnteil
            ZStack(alignment: .leading) {
                // Dieselbe helle Spur wie auf dem iPhone. Weiss mit 28 %
                // steht in BRAND 1 unter den gerechnet zu schwachen Werten.
                Capsule().fill(Color.white.opacity(0.18)).frame(height: dicke)
                Capsule().fill(.white)  // Akzent nur am Griff, wie auf iOS und tvOS
                    .frame(width: raum.size.width * anteil, height: dicke)
                // **Kerben an den Abschnittsgrenzen**, zwei Punkt in `grund`
                // — auf Spur und Balken zu sehen, wie am iPhone.
                ForEach(kerben, id: \.self) { stelle in
                    Rectangle().fill(Stil.grund)
                        .frame(width: 2, height: dicke)
                        .offset(x: raum.size.width * stelle - 1)
                }
                if zieht {
                    Circle().fill(Stil.akzent).frame(width: 18, height: 18)
                        .offset(x: raum.size.width * anteil - 9)
                }
            }
            .frame(height: mass.leiste)
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                if let schauAnteil {
                    vorschauKasten(anteil: schauAnteil)
                }
            }
            .onContinuousHover { lage in
                guard !zieht else { return }
                switch lage {
                case let .active(punkt):
                    hoverAnteil = min(max(punkt.x / raum.size.width, 0), 1)
                case .ended:
                    hoverAnteil = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { wert in
                        zieht = true
                        amRegler = true
                        let roh = min(max(wert.location.x / raum.size.width, 0), 1)
                        // **An den Kerben rastet er ein** (`Kerbenfang`) — mit
                        // dem Tick des Trackpads statt der Haptik des iPhones;
                        // eine Maus ohne Force Touch rastet still ein.
                        if dauer > 0,
                           let kerbe = Kerbenfang.kerbe(wert: Double(roh) * dauer, bis: dauer,
                                                         marken: marken,
                                                         breite: Double(raum.size.width)) {
                            zugAnteil = CGFloat(kerbe / dauer)
                            if eingerastet != kerbe {
                                eingerastet = kerbe
                                NSHapticFeedbackManager.defaultPerformer
                                    .perform(.alignment, performanceTime: .now)
                            }
                        } else {
                            zugAnteil = roh
                            eingerastet = nil
                        }
                    }
                    .onEnded { _ in
                        eingerastet = nil
                        let ziel = dauer * zugAnteil
                        position = ziel
                        springe(ziel)
                        zieht = false
                        amRegler = false
                        hoverAnteil = nil
                    }
            )
        }
        .frame(height: mass.leiste)
        // Für VoiceOver ein Regler mit Stelle und Länge, nicht eine
        // namenlose Fläche.
        .accessibilityElement()
        .accessibilityLabel("Abspielstelle")
        .accessibilityValue(String(localized: "\(Spielzeit.text(position)) von \(Spielzeit.text(dauer))"))
        .accessibilityAdjustableAction { richtung in
            let schritt = max(dauer / 20, 10)
            switch richtung {
            case .increment: let z = min(dauer, position + schritt); position = z; springe(z)
            case .decrement: let z = max(0, position - schritt); position = z; springe(z)
            @unknown default: break
            }
        }
    }

    /// **Über dem Zeiger oder Griff: Vorschaubild, darunter die Zeit.** Ohne
    /// Trickplay am Server nur die Zeit — kein leerer Kasten. Wörtlich das
    /// Bild von iOS' `vorschauKasten`.
    ///
    /// **Als eigene `GeometryReader`, nicht mit der Breite von aussen** —
    /// genau wie auf iOS: `.position(x:y:)` setzt die Mitte innerhalb des
    /// eigenen Rahmens, und der muss deshalb selbst über die volle Breite der
    /// Leiste reichen, nicht nur über die schmale Breite des Kastens.
    private func vorschauKasten(anteil: CGFloat) -> some View {
        GeometryReader { g in
            let stelle = dauer * anteil
            let bild = vorschau(stelle)
            let box: CGFloat = 170
            let hoehe = box * 9 / 16
            let halb = (bild == nil ? 40 : box / 2)
            let x = min(max(g.size.width * anteil, halb), max(g.size.width - halb, halb))
            VStack(spacing: 6) {
                if let bild {
                    Image(decorative: bild, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: box, height: hoehe)
                        .clipShape(RoundedRectangle(cornerRadius: Stil.ecke,
                                                    style: .continuous))
                        // `rand` ist der Token fuer die wenigen Stellen, die
                        // wirklich eine Kante brauchen — ein Vorschaubild
                        // ueber bewegtem Bild ist eine davon.
                        .overlay(RoundedRectangle(cornerRadius: Stil.ecke,
                                                  style: .continuous)
                            .strokeBorder(Stil.rand, lineWidth: 1))
                }
                Text(Spielzeit.text(stelle))
                    .font(.system(size: mass.zeit, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .fixedSize()
            .position(x: x, y: -((bild == nil ? 0 : hoehe + 6) + mass.zeit) / 2 - 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// **„Vorspann überspringen" / „Nächste Folge" — derselbe Knopf.** Wörtlich
/// das Bild von iOS' `Angebotsknopf`: weiße Pille, dunkle Schrift — die
/// Akzentfarbe gehört im Player allein dem Griff der Leiste beim Ziehen. Den
/// Countdown trägt seit 1.0.5 die Karte (``Folgenkartenansicht``), nicht mehr
/// eine Füllung der Pille.
private struct Angebotsknopf: View {
    private static let dunkel = Stil.grund
    let angebot: Knopfangebot
    let aktion: () -> Void

    var body: some View {
        if angebot.sichtbar {
            Button(action: aktion) {
                HStack(spacing: 8) {
                    Image(systemName: "forward.end.fill")
                        .accessibilityHidden(true)
                    Text(verbatim: angebot.beschriftung)
                }
                .font(Stil.listentitel)
                .padding(.horizontal, 18)
                .frame(height: 40)
                .background(.white, in: RoundedRectangle(cornerRadius: Stil.eckeFeld,
                                                         style: .continuous))
            }
            .buttonStyle(Stil.Druckknopf())
            .foregroundStyle(Self.dunkel)
            .fixedSize()
            .accessibilityLabel(Text(verbatim: angebot.beschriftung))
        }
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
        // Der Stand **vor** dem Player, einmal gemerkt — siehe `aufraeumen`.
        if vollbildVorher == nil, let neues {
            vollbildVorher = neues.styleMask.contains(.fullScreen)
        }
        fenster = neues
        vollbildBeobachten()
        ampelNachziehen()
    }

    /// War das Fenster schon im Vollbild, als der Player aufging?
    ///
    /// `nil`, bis das Fenster da ist. Gemerkt wird der Stand, nicht der Weg
    /// hinein: ob der Knopf im Kopf, die Taste F oder die gruene Ampel das
    /// Vollbild eingeschaltet hat, spielt fuer den Rueckweg keine Rolle.
    @ObservationIgnored private var vollbildVorher: Bool?

    @ObservationIgnored private var vollbildwache: [NSObjectProtocol] = []

    /// **Beim Wechsel ins Vollbild und zurück neu entscheiden.**
    ///
    /// Im Vollbild lassen wir die Ampel dem System; kommt das Fenster zurück,
    /// muss unsere Regel wieder greifen. Ohne das bliebe sie nach dem
    /// Verlassen des Vollbilds stehen, obwohl die Steuerung längst weg ist.
    /// **Und der Vollbild-Knopf im Kopf muss sein Zeichen tauschen** — sonst
    /// zeigt er nach dem Wechsel weiter „hinein", wo es nur noch „heraus"
    /// geben kann.
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

    /// Die Ampel verschwindet im kleinen Fenster — dort gehört sie nicht hin —
    /// **und sie geht im Player mit der Steuerung.**
    ///
    /// Genau richtig: sie ist Bedienung, und Bedienung tritt nach vier
    /// Sekunden Ruhe zurück. Ein Film, über dem drei bunte Punkte kleben, ist
    /// kein Vollbild.
    ///
    /// **Im Vollbild fassen wir sie nicht an.** Dort blendet macOS die ganze
    /// Titelleiste samt Ampel von sich aus aus und schiebt sie herunter,
    /// sobald der Zeiger an den oberen Rand geht — so kennt man es vom Mac,
    /// und so soll es bleiben. Griffen wir zusätzlich in die Deckkraft ein,
    /// bliebe die Leiste beim Herunterschieben leer.
    ///
    /// Der Winkel des Players (jetzt: das X oben rechts) schliesst den
    /// **Player**, die Ampel das **Fenster**. Zwei Handlungen, zwei Orte.
    private var ampelSichtbar: Bool {
        if istVollbild { return true }
        return !istKlein && (!imPlayer || zeigerOben)
    }

    private func ampelNachziehen(weich: Bool = false) {
        guard let fenster else { return }
        // **Im Vollbild gar nichts.** Nicht nur „sichtbar lassen", sondern die
        // Knöpfe überhaupt nicht anfassen.
        //
        // Dort schiebt macOS die Titelleiste selbst herunter, sobald der
        // Zeiger an den oberen Rand geht — und animiert dabei genau diese
        // Ansichten. Legt man in demselben Moment eine eigene
        // `NSAnimationContext`-Gruppe auf ihre Deckkraft, ringen zwei
        // Animationen um dieselben Ansichten, und das System steht für einen
        // Moment.
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
        // nicht, wenn sie durch ist.
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
        // **Die App verlaesst den Player so, wie sie ihn betreten hat.**
        //
        // Das kleine Fenster nahm der Player schon immer zurueck, das
        // Vollbild nicht. Wer im Player auf Vollbild ging und ihn dann
        // schloss, stand mit der ganzen App im Vollbild. Rückmeldung vom 22.09.:
        // „Im Normalfall sollte die App dann wieder zurueck zu dem Stand
        // gehen, wo sie vorher war."
        //
        // Nur zurueck, wenn der Player es war: lief die App schon vorher im
        // Vollbild, bleibt sie dort — das hat jemand bewusst so eingestellt.
        if istVollbild, vollbildVorher == false {
            fenster?.toggleFullScreen(nil)
        }
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
                .symbolEffect(.bounce, options: .speed(1.7),
                              value: Stil.bewegungReduziert ? false : gedreht)
            Text(verbatim: "\(sekunden) s").font(Stil.kachel)
        }
        .foregroundStyle(.white)
        .frame(width: 108, height: 108)
        .background(.black.opacity(0.45), in: Circle())
        .onAppear { gedreht = true }
    }
}
