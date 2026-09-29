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
    /// `.regular` heißt auf dem iPhone: hochkant.
    @Environment(\.verticalSizeClass) private var hoehenklasse
    /// Mit VoiceOver oder Schaltersteuerung bleibt die Steuerung stehen: wer
    /// sie nicht sieht, findet sie nach dem Ausblenden nicht wieder — die
    /// Fläche darunter hat keinen Knopf, der sie zurückholt.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverAn
    @Environment(\.accessibilitySwitchControlEnabled) private var schalterAn

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

    @State private var stelltWiederHer = false
    /// Läuft gerade im kleinen Fenster.
    @State private var imKleinenFenster = false
    @State private var erstesBildDa = false
    /// Das Bild geht gerade als Karte an ein anderes Gerät.
    @State private var abgabeLaeuft = false
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
    /// Startstelle einer Folge aus der Folgenliste, bis die Schleife den
    /// Wechsel übernommen hat.
    @State private var startNachWechsel: Double?
    @State private var hinweis: String?

    @State private var position: Double = 0
    @State private var dauer: Double = 0
    @State private var laeuft = true
    @State private var amSchieben = false
    @State private var steuerungSichtbar = true
    /// Nimmt die Steuerung noch Tipps an? Bleibt beim Ausblenden stehen, bis
    /// die Blende durch ist — siehe `steuerungGreifbarNachziehen`.
    @State private var steuerungGreifbar = true
    @State private var letzterTipp: Date?
    /// Läuft gerade eine Spulkette — Doppeltipp und jeder weitere schnelle
    /// Tipp auf derselben Seite?
    @State private var inSpulkette = false
    @State private var letzteSeite = 0

    /// Sichtbar heisst: gewollt, Bild steht, kein Menue davor.
    ///
    /// Und nicht auf dem Fernseher: dort steuert `AVPlayerViewController`, und
    /// zwei Steuerungen uebereinander wuerden sich gegenseitig treffen.
    private var steuerungDa: Bool {
        schleierDa && !ebeneOffen
    }

    /// Eine der drei Ebenen — Audio & Untertitel, Folgen, Einstellungen.
    private var ebeneOffen: Bool { offeneEbene != nil }

    /// Steht gerade etwas im Bild, das der Stelle folgt? Sonst reicht der
    /// ganze Takt (`beobachten`).
    private var zeitSichtbar: Bool {
        schleierDa || ebeneOffen || angebotDa || kartenwechsel != nil
            || technikschild || amSchieben || !erstesBildDa
    }

    /// **Der Angebotsknopf unten rechts** — eine Regel, egal ob die Steuerung
    /// offen ist (17.09.2026): Überspringen steht die ersten sechs
    /// Sekunden des Abschnitts, danach nur mit der Steuerung
    /// (`Angebotsebene.knopfdauer`); die Karte „Nächste Folge" steht bei geschlossener Steuerung
    /// (`Angebotsebene.anzeige`), bei offener steht dort der normale Knopf.
    private var angebotDa: Bool {
        // Beim Spulen weicht sie der Vorschau über der Leiste.
        guard angebot.sichtbar, bildFrei, !ebeneOffen, !imKleinenFenster, !amSchieben,
              airplayPlan == nil, !wechselt else { return false }
        return ebene.anzeige.sichtbar || (steuerungDa && angebot == .naechsteFolge)
    }

    /// Der Schleier liegt auf dem Bild: bei offener Steuerung — und solange
    /// die Karte der nächsten Folge steht, damit sie im Vordergrund liest.
    private var abgedunkelt: Bool {
        schleierDa || (karteDa && kartenwechsel == nil)
    }

    /// Die Karte der nächsten Folge steht (oder zoomt gerade).
    private var karteDa: Bool {
        kartenwechsel != nil || (angebotDa && countdownAnteil != nil)
    }

    /// Der Knopf unten rechts — nicht, solange dort die Karte steht.
    private var knopfDa: Bool {
        angebotDa && countdownAnteil == nil && kartenwechsel == nil
    }

    /// Federn des Entwurfs, kritisch gedämpft (``Folgenkarte``).
    private static func feder(_ omega: Double) -> Animation {
        if Stil.bewegungReduziert { return Stil.blendeReduziert }
        let f = Folgenkarte.feder(omega)
        return .interpolatingSpring(mass: 1, stiffness: f.steifigkeit, damping: f.daempfung)
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
    /// Räumt die Sprunganzeige ab — je Sprung neu, damit in einer Spulkette
    /// nicht der erste Tipp die Anzeige des letzten wegnimmt.
    @State private var sprungAnzeigeAufgabe: Task<Void, Never>?
    /// Holt den Plan für AirPlay. Abbrechbar: wer zurückschaltet oder den
    /// Player schließt, bevor der Server antwortet, bekommt sonst doch noch
    /// den Wechsel auf den Fernseher.
    @State private var airplayAufgabe: Task<Void, Never>?

    /// Zaehlen die Ausloesungen je Richtung. Der Knopf dreht sich dadurch
    /// bei jedem Druck ein Stueck weiter, statt nur einmal.
    @State private var taktZurueck = 0
    @State private var taktVor = 0
    @State private var ausblendMarke = 0
    /// Ein Sprung, bei dem VLC noch nicht angekommen ist — bis dahin zeigt die
    /// Zeitleiste das Ziel. Die Regel steht in `Wiedergabetakt.Sprung`.
    @State private var sprung: Wiedergabetakt.Sprung?
    /// Die Füllung der Karte als durchgehende Bewegung (`Fuellungsuhr`).
    @State private var fuellungsuhr = Fuellungsuhr()
    @State private var zuletztGeschoben: Date?

    @State private var offeneEbene: Playerebene?
    /// Die zuletzt geöffnete Ebene — bleibt beim Schließen stehen, damit der
    /// Titel auch während der Ausblende der Folgen über ihnen liegt.
    @State private var zuletztGeoeffnet: Playerebene?
    /// Der nächste Plan kommt aus einer Qualitätswahl — für den Hinweis.
    @State private var qualitaetGewechselt = false
    /// Kein Knopf mehr dafür im Player; bleibt für Sperrbildschirm und
    /// Kontrollzentrum, die ein Tempo gemeldet haben wollen.
    @State private var tempo: Float = 1.0
    /// Vorschaubilder beim Spulen (Jellyfin-Trickplay).
    @State private var trickplay = Trickplaybilder()
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
    /// Die Karte der nächsten Folge wartet, solange die Steuerung offen ist
    /// — abgebrochen wird am X oder per Wisch (``Folgenkartenansicht``).
    @State private var ebene: Angebotsebene = {
        var e = Angebotsebene()
        e.karteWartetBeiSteuerung = true
        return e
    }()
    /// Spiegelt den Riegel von `folgenwechsel` für die Ansicht.
    @State private var wechselt = false
    /// Plan und Dateianfang der nächsten Folge, in den letzten Minuten geholt.
    @State private var vorbereitung = Folgenvorbereitung()
    /// Seit wann die nächste Folge geladen wird — für die Wechselzeit im
    /// Protokoll.
    @State private var wechselBeginn: Date?
    /// **Die Karte der nächsten Folge** (``Folgenkarte``, Variante C):
    /// solange sie ins Bild zoomt, gehalten — mit Folge und Countdownstand von
    /// eben, damit nichts blitzt, wenn der Wechsel das Angebot wegnimmt.
    @State private var kartenwechsel: Kartenwechsel?
    @State private var kartenfolge: Item?
    @State private var kartenuhr: Fuellungsuhr?
    @State private var kartenzoom: Double = 0
    @State private var kartenbild: Double = 1
    /// Das zuletzt sichtbare Angebot: der Knopf behält seine Beschriftung,
    /// während er ausblendet, statt leer aus dem Baum zu fallen.
    @State private var gezeigtesAngebot: Knopfangebot = .keiner

    /// Im Messlauf (`Wechsellauf -ohnevorpuffer`) abschaltbar, damit sich
    /// die Wechselzeit mit und ohne vergleichen lässt.
    private var vorpufferErlaubt: Bool {
        #if DEBUG
        return !Wechsellauf.ohneVorpuffer
        #else
        return true
        #endif
    }
    @State private var folgenwechsel = Folgenwechsel()
    /// Sperrbildschirm, Kontrollzentrum, Kopfhörertasten und Anrufe.
    @State private var zentrale = Wiedergabezentrale()

    /// Breite des Fensters. Im geteilten Bildschirm bleiben davon 320 übrig,
    /// und darin läuft eine Steuerung, die für 844 gebaut ist, aus dem Bild.
    @State private var fensterbreite: CGFloat = 0

    /// **Gemeinsam schauen.** Gesetzt beim Öffnen, wenn der Titel der ist,
    /// den die Gruppe schaut. Die Gruppe selbst hält ``Gemeinsammodell``.
    @State private var gemeinsamAn = false
    @State private var bruecke = Gemeinsamspieler()
    private var gemeinsam: Gemeinsammodell { .geteilt }
    /// Läuft dieser Player gerade in einer Gruppe? Dann gehen Anhalten,
    /// Weiter und Springen als Bitte an den Server, nicht an VLC.
    private var inGruppe: Bool { gemeinsamAn && gemeinsam.gruppe != nil }

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
                        Spacer(minLength: 0)
                        Symbolknopf(symbol: "xmark", beschriftung: "Player schließen",
                                    mass: mass) { schliessen() }
                    }
                    .padding(.horizontal, mass.seite)
                    .padding(.top, mass.oben)
                    Spacer(minLength: 0)
                }
                .ignoresSafeArea(edges: mass.obenUebergehen)
                .transition(.opacity)
            }
        }
        // Derselbe Takt, in dem jede andere Ansicht ihren Bereich tauscht
        // (BRAND 6). Vorher easeOut 0,2 von Hand — dieselbe Dauer, aber eine
        // eigene Zahl für eine Rolle, die schon einen Token hat.
        .animation(Stil.bereichswechsel, value: drehungFertig)
        .transition(.opacity)
    }

    /// Was im großen Bild steht, während nebenan im kleinen Fenster läuft.
    private var kleinerHinweis: some View {
        VStack(spacing: 12) {
            Image(systemName: "pip.fill")
                // Vorher `.light` — das Gewicht ist gestrichen, es gibt nur
                // noch Regular, Medium und Semibold (BRAND 2). Medium wie die
                // übrigen Zeichen im Player. Der Grad 30 bleibt: ein Zeichen,
                // keine Schrift.
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Stil.schriftSehrLeise)
            Text("Läuft im kleinen Fenster")
                // Dieselbe Stufe wie vorher (15 Regular), jetzt als Token.
                .font(Stil.koerper)
                .foregroundStyle(Stil.schriftLeise)
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
                // Vorher `.subheadline.weight(.medium)` — 15 Medium steht in
                // keiner Leiter. Eine Zeile, die etwas sagt, ist 15 Semibold.
                .font(Stil.listentitel)
            Text("Läuft weiter, sobald das Netz zurück ist.")
                // Vorher `.caption`; 12 Regular heißt hier `klein`.
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftLeise)
        }
        // Gelesen wird `schrift`, nicht rohes Weiß — vorher `.white`.
        .foregroundStyle(Stil.schrift)
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous))
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    /// Der Player samt Blenden, Tasten und Aufräumen. Aus `body`
    /// herausgezogen, weil die Kette sonst zu lang für die Typprüfung wird.
    private var grundflaeche: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoSurfaceHost(url: plan.url, startAt: startAt, container: plan.container,
                             puffer: model.pufferstufe,
                             untertitel: model.untertiteldateien(plan),
                             softwareDekoder: plan.softwareDekoder,
                             spuren: spurwunsch(item, plan)) {
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
                // Unsichtbare Flächen ohne Namen: VoiceOver hat dafür die
                // Knöpfe der Steuerung, die mit VoiceOver stehen bleiben.
                // Abspielen und Anhalten geht zusätzlich mit dem
                // Zwei-Finger-Doppeltipp (magischer Tipp).
                .accessibilityHidden(true)

            // Zoomt die Karte ins Bild, deckt sie den Wechsel — kein
            // Ladeschirm darüber.
            if !bildFrei, kartenwechsel == nil { startschleier }

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
                .opacity(abgedunkelt ? 1 : 0)
                .animation(abgedunkelt ? .snappy(duration: 0.18, extraBounce: 0)
                                       : .smooth(duration: 0.34),
                           value: abgedunkelt)

            // **Über dem Schleier**: steht die Karte, dunkelt er das Bild ab
            // wie bei offener Steuerung, und sie liegt davor.
            kartenebene

            // **Das Technikschild.** Eine Auskunft, kein Bedienteil: es nimmt
            // nichts an. **Direkt auf dem Film** (22.09.2026): über dem
            // Schleier, damit es lesbar bleibt, aber unter Titel, Knöpfen und
            // Leiste — und damit auch unter den Ebenen. **Es gleitet mit der
            // Steuerung** (22.09.2026): offen steht es unter der
            // Titelzeile, zu rückt es an den oberen Rand, wo sie stand — so
            // ist es nie im Weg. Bewegung statt Blende, dieselbe Kurve wie die
            // Steuerung; mit reduzierter Bewegung springt es.
            if technikschild {
                Technikschild(plan: plan, werte: spielwerte, flaeche: surface,
                              schirmHertz: schirmtakt.hertz)
                    .padding(.leading, mass.seite)
                    .padding(.top, mass.oben + mass.knopf + Stil.kachelAbstand)
                    .offset(y: steuerungDa ? 0 : -(mass.knopf + Stil.kachelAbstand))
                    .animation(Stil.bewegungReduziert ? nil
                               : Self.kurve(da: steuerungDa, ebene: ebeneOffen),
                               value: steuerungDa)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .ignoresSafeArea(edges: mass.obenUebergehen)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            Group {
                // Eigene Ebene statt zwischen Kopf und Fuss gestapelt: der
                // Fuss ist hoeher als der Kopf, dadurch lag die Mitte
                // zwischen beiden sichtbar ueber der Bildmitte.
                // Beim Spulen zählt nur die Leiste — die Mitte weicht.
                mittelsteuerung
                    .opacity(amSchieben ? 0 : 1)
                    .allowsHitTesting(!amSchieben)
                    // **Mitte des Bildschirms, nicht des sicheren Bereichs.**
                    // Quer ist der sichere Bereich unten 21 pt höher als oben;
                    // die Knöpfe saßen dadurch ein Stück über der Bildmitte.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    kopf
                    Spacer(minLength: 0)
                    fuss
                }
                // **Unten im sicheren Bereich, oben nicht.**
                //
                // Die Leiste lag vorher außerhalb davon, auf Höhe des
                // Home-Indikators, und wurde beim Greifen mit ihm verwechselt.
                // Jetzt sitzt sie `mass.unten` darüber. Oben hält das Querformat
                // ohnehin nichts frei; waagerecht bleibt der sichere Bereich
                // wichtig, dort sitzt die Aussparung.
                .ignoresSafeArea(edges: mass.obenUebergehen)
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
            // **Greifbar, solange man sie sieht.** Vorher war die Steuerung
            // schon beim ersten Bild der Ausblende taub: wer den Knopf noch
            // sah und traf, landete in der Tippfläche darunter.
            .allowsHitTesting(steuerungGreifbar)
            .task(id: steuerungDa) { await steuerungGreifbarNachziehen() }
            // **Federn, damit ein zweiter Tipp nicht warten muss.** Die
            // Asymmetrie bleibt — schnell auf, gemaechlich zu —, aber eine
            // feste Dauer laesst sich nicht umlenken: wer zweimal kurz
            // hintereinander tippt, sah die Blende von vorn beginnen.
            .animation(Self.kurve(da: steuerungDa, ebene: ebeneOffen), value: steuerungDa)

            // **Die Einblendung — und derselbe Knopf bei offener Steuerung.**
            // Ein Tipp darauf führt aus; ein Tipp daneben öffnet wie immer die
            // Steuerung. Beide stehen an genau dieser einen Stelle (17.09.2026): vorher lag der Knopf bei offener Steuerung in der
            // Titelzeile, zehn Punkt höher, und sprang beim Aufblenden. Der Fuß
            // hält ihm dafür nur den Platz frei. Überspringen steht sechs
            // Sekunden von selbst, danach kommt und geht es mit der Steuerung
            // (`Angebotsebene.knopfdauer`) — immer mit denselben Kurven wie
            // sie.
            //
            // Rechtsbündig direkt über der Leiste, mit denselben Maßen wie der
            // Fuß — so überlappt er sie nie, ob die Steuerung offen ist oder
            // nicht.
            // **Weich weg, nicht zack weg** (22.09.2026): das Entfernen
            // aus dem Baum lief trotz Transition hart. Der Knopf bleibt
            // deshalb im Baum, solange es ein Angebot gibt, und kommt und
            // geht über die Deckkraft — die Transition gilt nur noch am
            // Anfang und Ende des Abschnitts.
            // **Bleibt im Baum und geht über Deckkraft und Weg** (26.09.2026):
            // aus dem Baum genommen verschwand er in einem Bild — beim Tippen
            // wie beim Folgenwechsel. Die Beschriftung bleibt dabei die zuletzt
            // gezeigte. Den Countdown zur nächsten Folge trägt die Karte.
            if gezeigtesAngebot.sichtbar {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Angebotsknopf(angebot: gezeigtesAngebot,
                                      aktion: angebotAusfuehren)
                            // VoiceOver: Wischen mit zwei Fingern (Z) sagt ab.
                            .accessibilityAction(.escape) { _ = ebene.schliessen() }
                    }
                }
                .padding(.horizontal, mass.seite)
                .padding(.bottom, mass.unten + mass.leiste + mass.ueberLeiste)
                .ignoresSafeArea(edges: mass.obenUebergehen)
                .offset(y: knopfDa || Stil.bewegungReduziert ? 0 : 6)
                .opacity(knopfDa ? 1 : 0)
                .allowsHitTesting(knopfDa)
                .accessibilityHidden(!knopfDa)
                .animation(Stil.bewegungReduziert ? Stil.blendeReduziert
                           : knopfDa ? .smooth(duration: 0.3) : .smooth(duration: 0.34),
                           value: knopfDa)
            }

            if let sprungAnzeige { sprungRueckmeldung(sprungAnzeige) }

            // **Was in der Gruppe passiert, kurz oben** — damit niemand
            // rätselt, warum der Film steht.
            if inGruppe, let ereignis = gemeinsam.ereignis {
                Gruppenereignis(symbol: ereignis.symbol, text: ereignis.text)
                    .padding(.top, mass.oben + mass.knopf + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: mass.obenUebergehen)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .id(ereignis.id)
                    .zIndex(4)
            }
            if inGruppe, let fehler = gemeinsam.fehler {
                Hinweisstreifen(text: fehler) { gemeinsam.fehler = nil }
                    .zIndex(4)
            }
            if wechselt, kartenwechsel == nil { Lader() }

            // **Die drei Ebenen.** Vollbild über dem Video, die Steuerung
            // darunter weicht (`steuerungDa`), der Ausblend-Zeitgeber ruht.
            //
            // Montiert nur, solange eine offen ist: die Spurspalten lesen
            // `surface?.tonspuren` und `?.untertitelspuren` direkt aus
            // VLCKit, und dauerhaft montiert wäre das bei jedem Takt.
            if let offeneEbene {
                ebenenansicht(offeneEbene)
                    .transition(.opacity)
                    .zIndex(5)
            }

            // Über den Ebenen nur bei den Folgen — dort bleibt er stehen.
            // Sonst unter ihnen, damit er mit der Metazeile zusammen unter
            // dem Weichzeichner verschwindet, nicht erst danach.
            stehenderTitel
                .zIndex(zuletztGeoeffnet == .folgen ? 6 : 3)

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
                        else { schliessen() }
                    },
                    fehler: { text in
                        // **Zurueck aufs Geraet, nicht schwarz stehenbleiben.**
                        // Nimmt der Empfaenger den Strom nicht, ist ein
                        // Schwarzbild auf dem Fernseher das Schlechteste von
                        // allem: der Film laeuft nirgends. Also weiter auf dem
                        // Telefon, mit Ansage.
                        hinweis = String(localized: "Der Fernseher kann diesen Film nicht abspielen (\(text)). Er läuft auf dem iPhone weiter.")
                        airplayUmschalten(false)
                    }
                )
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .animation(Stil.einblenden, value: technikschild)
        .animation(Stil.einblenden, value: gemeinsam.ereignis)
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
        // Auf den Fernseher und zurück tauscht den ganzen Bereich aus, also der
        // Bereichswechsel-Token. Vorher easeInOut 0,2 von Hand.
        .animation(Stil.bereichswechsel, value: airplayPlan?.url)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // Am Stapel gemessen, nicht an der Videofläche: die meldet nach der
        // Rückkehr aus Bild-im-Bild noch die Größe des kleinen Fensters.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { neu in
            fensterbreite = neu
        }
        .onAppear {
            model.fernbefehl = ausfuehren
            if gemeinsam.gehoertZurGruppe(item.id) {
                brueckeNachziehen()
                gemeinsam.anschliessen(bruecke)
                gemeinsamAn = true
            }
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
            // Schließen heißt verlassen (Entwurf A).
            if gemeinsamAn { gemeinsam.abtrennen() }
            fernziel.aufhoeren()
        }
        .accessibilityAction(.magicTap) { spielenUmschalten() }
        // Tastatur am iPad — siehe `tastenkuerzel`.
        .background { tastenkuerzel }
    }

    var body: some View {
        grundflaeche
        .task(id: ausblendMarke) {
            // Im Stehen nichts wegnehmen: wer pausiert hat, schaut gerade
            // nicht aufs Bild, sondern will die Steuerung sehen.
            guard steuerungSichtbar, laeuft, !voiceOverAn, !schalterAn else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !amSchieben, !ebeneOffen else { return }
            steuerungSichtbar = false
        }
        // Vorher easeInOut 0,15 — das liegt zwischen zwei Stufen. Die Marke
        // steht nur 700 ms, deshalb die kürzere: Umschalten 0,10.
        .animation(Stil.umschalten, value: sprungAnzeige?.richtung)
        .animation(Self.ebenenKurve, value: offeneEbene)

        // Auch die Griffe erneuern: sonst rechnet `umschalten` weiter mit
        // dem Stand von vorhin.
        // Pause hält auch die Füllung der Karte sofort an, nicht erst im Takt.
        .onChange(of: laeuft) { _, _ in ausblendMarke += 1; zentraleUebernehmen(); fuellungStellen() }
        // **Nach dem Schliessen faengt die Uhr von vorn an.**
        //
        // Der Riegel oben (`!ebeneOffen`) haelt die Steuerung
        // richtigerweise offen, solange die Tafel steht -- aber er sitzt
        // *nach* dem Schlafen. Die Aufgabe endet damit, ohne etwas
        // wegzunehmen, und ohne neue Marke laeuft keine zweite an: die
        // Steuerung waere nach dem Schliessen dauerhaft stehen geblieben.
        .onChange(of: ebeneOffen) { _, offen in if !offen { ausblendMarke += 1 } }
        // Die Einblendung hört auf die gewollte Steuerung, nicht auf die
        // sichtbare: beim Öffnen steht sie schon auf „an", bevor das Bild da
        // ist, und ihr erstes Ausblenden ist kein Blick in die Steuerung, der
        // „Rückblick überspringen" wegschicken dürfte.
        .onChange(of: angebot, initial: true) { _, neu in
            if neu.sichtbar { gezeigtesAngebot = neu }
        }
        .onChange(of: karteDa) { _, da in
            guard kartenwechsel == nil else { return }
            Protokoll.schreib(da ? "[Karte] erscheint bei \(Int(position)) s von \(Int(dauer)) s"
                                 : "[Karte] geht (abgesagt oder Steuerung)")
        }
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
                    guard !zoomSchonGeschaltet, !imKleinenFenster, !ebeneOffen else { return }
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
        // Je Titel einmal nachsehen, ob der Server Vorschaubilder hat.
        .task(id: item.id) { await trickplay.laden(model: model, item: item, plan: plan) }
        // Das Folgenbild für eine mögliche Übergabe schon bereit — die Karte
        // des Abgebers braucht es im ersten Bild (``Uebergabeabgang``).
        .task(id: item.id) { await Uebergabeabgang.vorladen(item, model: model) }
        .task(id: item.id) {
            if item.type == "Episode" { await FolgenEbene.vorladen(model: model, item: item) }
        }
        // Erst danach steht fest, ob es einen „Weiter"-Knopf geben darf.
        .task { await nachschlagen(fuer: item) }
        .onChange(of: dauer) { _, _ in zentraleMelden() }
        .onAppear {
            model.playerOffen = true
            // **Vor** dem Anfordern fragen: danach steht die Lage schon quer.
            // Im eigenen Rahmen dreht UIKit schon beim Zeigen mit — der
            // Player erscheint gleich quer, zu warten gibt es nichts.
            let imRahmen = Playerrahmen.aktiv != nil
            drehungErwartet = !imRahmen && Orientierung.drehungErwartet(querformatFest: querformatFest)
            drehungAngefordert = Date()
            Protokoll.schreib("[Drehung] angeordnet · erwartet=\(drehungErwartet)"
                + " · Sperre=\(querformatFest) · Rahmen=\(imRahmen)")
            Orientierung.shared.playerGeoeffnet(querformatFest: querformatFest, anfordern: !imRahmen)
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
            sprungAnzeigeAufgabe?.cancel()
            airplayAufgabe?.cancel()
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
            Uebergabebuehne.geteilt.spielerWeg(item.id)
            // Im eigenen Rahmen hat der Übergang schon zurückgedreht.
            Orientierung.shared.playerGeschlossen(anfordern: Playerrahmen.aktiv == nil)
            model.playerOffen = false
        }
    }

    /// **Eine Blende für Ebene und Steuerung.** Öffnet eine Ebene, blendet
    /// die Steuerung darunter im **selben Takt** aus, in dem der
    /// Weichzeichner einblendet. Vorher lief sie mit ihrer gemächlichen
    /// Ausblende (0,34 s) weiter, während die Ebene nach 0,2 s stand — Teile
    /// schimmerten verspätet durch den Weichzeichner.
    ///
    /// **Eine Feder, keine feste Dauer** — wie die Steuerung: wer eine Ebene
    /// öffnet und gleich wieder schließt, lenkt die laufende Blende um, statt
    /// sie von vorn beginnen zu sehen. Mit reduzierter Bewegung die kurze
    /// Überblendung aus `Stil`.
    static var ebenenKurve: Animation {
        Stil.bewegungReduziert ? Stil.blendeReduziert : .snappy(duration: 0.2, extraBounce: 0)
    }

    /// Aufblenden federnd und schnell, Ausblenden gemächlich — außer eine
    /// Ebene nimmt ihren Platz ein, dann im Takt der Ebene.
    static func kurve(da: Bool, ebene: Bool) -> Animation {
        if Stil.bewegungReduziert { return Stil.blendeReduziert }
        if da { return .snappy(duration: 0.18, extraBounce: 0) }
        return ebene ? ebenenKurve : .smooth(duration: 0.34)
    }

    /// Wie lange die Ausblende aus `kurve` läuft.
    static func ausblenddauer(ebene: Bool) -> Duration {
        if Stil.bewegungReduziert { return .milliseconds(140) }
        return ebene ? .milliseconds(200) : .milliseconds(340)
    }

    /// Aufblenden macht sofort greifbar, Ausblenden erst nach der Blende.
    /// Kommt die Steuerung vorher zurück, bricht `task(id:)` das Warten ab.
    private func steuerungGreifbarNachziehen() async {
        guard !steuerungDa else { steuerungGreifbar = true; return }
        try? await Task.sleep(for: Self.ausblenddauer(ebene: ebeneOffen))
        guard !Task.isCancelled, !steuerungDa else { return }
        steuerungGreifbar = false
    }

    /// Trägt den jetzigen Stand in die Brücke zur Gruppe und gibt ihr den
    /// Takt — siehe ``Gemeinsamspieler``, warum ein Objekt und kein Abschluss.
    private func brueckeNachziehen() {
        bruecke.flaeche = surface
        bruecke.titelID = item.id
        bruecke.istBereit = (surface?.startFertig ?? false) && bildFrei && !wechselt
        bruecke.sprungZeigen = { ziel in gesprungen(auf: ziel) }
        bruecke.titelWechseln = { folge, _, ab in zurNaechstenFolge(folge, ab: ab) }
        gemeinsam.spielertakt()
    }

    /// **Die Wiedergabe geht an ein anderes Gerät** (``Uebergabeabgang``).
    /// Die Stelle geht sofort an den Server — drüben wird auf sie gewartet —,
    /// die Steuerung weg, das Bild steht bei 0,12 s und geht als Karte ab.
    private func abgeben(an ziel: String, flaeche: VLCPlayerView) {
        guard !abgabeLaeuft else { return }
        abgabeLaeuft = true
        let stelle = position
        Task { await model.reportStopped(item: item, plan: plan, seconds: stelle) }
        var ohne = Transaction()
        ohne.disablesAnimations = true
        withTransaction(ohne) { steuerungSichtbar = false }
        Uebergabeabgang.starten(flaeche: flaeche, ziel: ziel, titel: item, model: model,
                                anhalten: { flaeche.pause() },
                                fertig: { flaeche.stop(); schliessen() })
    }

    /// Auf dem iPhone schließt der eigene Rahmen (`Playerrahmen`) — dort
    /// dreht UIKit im selben Übergang zurück ins Hochformat.
    private func schliessen() {
        Protokoll.schreib("[Player] Schließen · Wechsel \(folgenwechsel.phase) · Karte \(kartenwechsel != nil) · Rahmen \(Playerrahmen.aktiv != nil)")
        if let rahmen = Playerrahmen.aktiv {
            rahmen.schliessen()
        } else {
            Orientierung.shared.playerGeschlossen()
            dismiss()
        }
    }

    /// **Tastatur am iPad, wie im Mac-Player:** Leertaste hält an und
    /// spielt, die Pfeile springen um die eingestellte Weite. Bei offener
    /// Ebene gehören die Tasten ihr — wer dort durch die Tonspuren geht,
    /// soll nicht den Film anhalten. Eigene Eigenschaft, weil `body` sonst
    /// zu lang für die Typprüfung wird.
    private var tastenkuerzel: some View {
        Group {
            Button(laeuft ? "Anhalten" : "Abspielen") { spielenUmschalten() }
                .keyboardShortcut(.space, modifiers: [])
            Button("\(model.zurueckSekunden) Sekunden zurück") {
                spulen(Int32(-model.zurueckSekunden))
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            Button("\(model.vorSekunden) Sekunden vor") {
                spulen(Int32(model.vorSekunden))
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .disabled(ebeneOffen)
        .opacity(0)
        .accessibilityHidden(true)
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
                .onTapGesture {
                    spielenUmschalten()
                }
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
    /// geschah (beides 17.09.2026).
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
        let fenster = inSpulkette ? Self.kettentipp : Self.doppeltipp
        if let vorher = letzterTipp, letzteSeite == richtung,
           jetzt.timeIntervalSince(vorher) < fenster {
            // **Eine Kette, kein Paar.** Vorher stand hier `letzterTipp = nil`,
            // und jeder dritte schnelle Tipp schaltete die Steuerung, statt
            // weiterzuspulen. Jetzt verlängert jeder Tipp die Kette.
            letzterTipp = jetzt
            inSpulkette = true
            // Der erste Tipp hat schon geschaltet. Das bleibt so — was
            // einmal dasteht, wird nicht wieder weggenommen.
            if steuerungSichtbar { ausblendenVerschieben() }
            spulen(Int32(richtung < 0 ? -model.zurueckSekunden : model.vorSekunden))
            return
        }
        letzterTipp = jetzt
        letzteSeite = richtung
        inSpulkette = false
        steuerungUmschalten()
    }

    /// Wie lange ein Tipp auf seinen zweiten wartet.
    private static let doppeltipp: Double = 0.26
    /// Wie lange eine laufende Spulkette auf den nächsten Tipp wartet —
    /// länger als der Doppeltipp, weil man beim Spulen im eigenen Takt tippt
    /// und dabei auf die Sprunganzeige schaut.
    private static let kettentipp: Double = 0.5

    // MARK: - Kopf, Mitte, Fuß

    /// Maße für iPhone und iPad — geteilt mit den Ebenen, damit deren X
    /// genau auf dem X des Players liegt.
    private var mass: Playermass {
        Playermass(pad: Stil.amPad, imFenster: imFenster,
                   hochkant: !Stil.amPad && hoehenklasse == .regular)
    }

    /// Bei einer Folge die Serie, sonst der Titel selbst.
    private var titelzeile: String {
        if item.type == "Episode", let serie = item.seriesName, !serie.isEmpty { return serie }
        return item.name
    }

    /// „Staffel 1 · Folge 3" — beim Film Jahr, Laufzeit und Genre.
    private var metatext: String? {
        if item.type == "Episode" {
            if let staffel = item.parentIndexNumber, let folge = item.indexNumber {
                return String(localized: "Staffel \(staffel) · Folge \(folge)")
            }
            return item.kontextzeile
        }
        let zeile = item.nebenzeile
        return zeile.isEmpty ? nil : zeile
    }

    /// Nur Folgen einer Serie haben eine Folgenliste.
    private var hatFolgen: Bool { item.type == "Episode" && item.seriesId != nil }

    /// **Oben links der Titel, oben rechts nur Symbole.**
    ///
    /// Kein Bild-im-Bild-Knopf mehr: das kleine Fenster startet beim
    /// Hochwischen von selbst. Kein Tempo, keine Auskunft — beides stand im
    /// alten Wiedergabemenü und fällt mit ihm weg. Beim Spulen bleibt nur der
    /// Titel; die Symbole weichen der Vorschau.
    /// Die Knöpfe oben rechts — auch als unsichtbarer Platzhalter in
    /// `stehenderTitel`, damit der Titel dort genauso breit wird.
    private var symbolreihe: some View {
        HStack(spacing: mass.pad ? 6 : 2) {
            Symbolknopf(symbol: "captions.bubble", beschriftung: "Audio & Untertitel",
                        mass: mass) { ebeneOeffnen(.spuren) }
            if hatFolgen {
                Symbolknopf(symbol: "rectangle.stack", beschriftung: "Folgen",
                            mass: mass) { ebeneOeffnen(.folgen) }
            }
            Symbolknopf(symbol: "slider.horizontal.3", beschriftung: "Einstellungen",
                        mass: mass) { ebeneOeffnen(.einstellungen) }
            Symbolknopf(symbol: "xmark", beschriftung: "Player schließen",
                        mass: mass) { schliessen() }
        }
    }

    /// **Der Titel oben links, eine Ebene über allem.** Bei offener
    /// Folgenebene bleibt er genau hier stehen; läge er im Kopf, blendete er
    /// mit der Steuerung aus und in der Ebene wieder ein — er flackerte.
    private var stehenderTitel: some View {
        let da = steuerungDa || offeneEbene == .folgen
        return HStack(alignment: .top, spacing: 12) {
            Text(verbatim: titelzeile)
                // 20 Semifett — die Reihenueberschrift aus der Leiter. Vorher
                // 19 (iPhone) und 22 (iPad) in Bold: ein Grad, den es in
                // keiner Leiter gibt, und Bold steht genau einmal, am
                // Seitentitel. Die Begruendung stehe bei `Playermass`.
                .font(.system(size: mass.titel, weight: .semibold))
                // Vorher rohes `.white`; gelesen wird `schrift`.
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
            Spacer(minLength: 0)
            symbolreihe
                .hidden()
                .accessibilityHidden(true)
        }
        .padding(.horizontal, mass.seite)
        .padding(.top, mass.oben)
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(edges: mass.obenUebergehen)
        .allowsHitTesting(false)
        .opacity(da ? 1 : 0)
        .animation(Self.kurve(da: da, ebene: ebeneOffen), value: da)
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
            // Vorher rohes `.white`; gelesen wird `schrift`. Die Metazeile
            // darunter setzt sich ihr `schriftLeise` selbst.
            .foregroundStyle(Stil.schrift)

            Spacer(minLength: 0)

            symbolreihe
            .opacity(amSchieben ? 0 : 1)
            .allowsHitTesting(!amSchieben)
        }
        .padding(.horizontal, mass.seite)
        .padding(.top, mass.oben)
        .overlay(alignment: .bottom) {
            // Unter der Kopfzeile, mittig: dort kommt sie weder der Leiste
            // noch dem Überspringen-Knopf in die Quere.
            if let hinweis {
                Text(hinweis)
                    // Vorher `.caption2` (11 Regular) — 11 steht nur als
                    // Semibold in der Leiter; ein Satz ist eine Angabe, also 12.
                    .font(Stil.klein).foregroundStyle(Stil.schrift)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, mass.seite)
                    .offset(y: 22)
                    .task {
                        try? await Task.sleep(for: .seconds(5))
                        self.hinweis = nil
                    }
            }
        }
    }

    private func ebeneOeffnen(_ ziel: Playerebene) {
        ausblendMarke += 1
        zuletztGeoeffnet = ziel
        offeneEbene = ziel
    }

    private func ebeneSchliessen() {
        offeneEbene = nil
    }

    @ViewBuilder
    private func ebenenansicht(_ welche: Playerebene) -> some View {
        switch welche {
        case .spuren:
            SpurenEbene(surface: surface, mass: mass, schliessen: ebeneSchliessen)
        case .einstellungen:
            EinstellungsEbene(surface: surface, mass: mass, schlafminuten: $schlafminuten,
                              qualitaet: qualitaetswahl,
                              gemeinsam: inGruppe ? gemeinsam : nil,
                              gruppeVerlassen: { schliessen() },
                              schliessen: ebeneSchliessen)
        case .folgen:
            FolgenEbene(model: model, item: item, titel: titelzeile, mass: mass,
                        schliessen: ebeneSchliessen) { folge in
                ebeneSchliessen()
                // Die laufende Folge antippen heißt: weiterschauen.
                guard folge.id != item.id else { return }
                // In der Gruppe wechselt niemand allein: die Wahl setzt die
                // Warteschlange, und alle laden die Folge.
                if inGruppe { gemeinsam.bitteTitel(folge.id); return }
                zurNaechstenFolge(folge, ab: folge.fortsetzenAb ?? 0)
            }
        }
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

    /// Nur die Leiste, über die volle Breite: links die verstrichene Zeit,
    /// rechts die Restzeit. Der Titel steht jetzt oben.
    private var fuss: some View {
        Zeitzeile(position: $position, dauer: dauer, amSchieben: amSchieben,
                  schrift: mass.zeit, pad: mass.pad,
                  vorschau: { trickplay.bild(bei: $0, model: model) },
                  // **Beide Grenzen, nicht nur der Anfang.** Wo der Vorspann
                  // anfaengt, sagt allein noch nicht, wo er aufhoert — und
                  // genau das will man sehen, bevor man greift.
                  marken: abschnitte.flatMap { [$0.von, $0.bis] }) { schiebt in
            if schiebt {
                // **Der Regler ist das Bauteil, an dem der Finger am
                // laengsten liegt** — und die ganze App hatte bis zum 21.09.
                // genau eine Haptik, keine davon im Player. Anfassen und
                // Loslassen sind die zwei Momente, in denen die Hand eine
                // Antwort erwartet: leicht beim Greifen, mittel beim
                // Absetzen, weil der Sprung dann wirklich geschieht.
                // `Stil.ruck` haelt sich selbst an `bewegungReduziert`.
                Stil.ruck(.leicht)
                amSchieben = true
                zuletztGeschoben = Date()
                ausblendMarke += 1
            } else {
                // Ausdrücklich zurücksetzen: sonst bliebe amSchieben
                // stehen und die Zeitanzeige würde nie mehr nachgeführt.
                amSchieben = false
                Stil.ruck(.mittel)
                if inGruppe { gemeinsam.bitteSpringen(auf: position) }
                else { surface?.seek(toSeconds: position) }
                gesprungen(auf: position)
                ausblendenVerschieben()
            }
        }
        .frame(height: mass.leiste)
        .padding(.horizontal, mass.seite)
        .padding(.bottom, mass.unten)
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
                //
                // **Bei reduzierter Bewegung springt es um, statt zu
                // wechseln.** Der Massstab am Knopf fragt die Einstellung
                // schon; dieser Effekt tat es nicht, und damit lief mitten im
                // Player genau die Bewegung weiter, die jemand abgeschaltet
                // hat.
                .contentTransition(Stil.bewegungReduziert
                                   ? .identity
                                   : .symbolEffect(flott ? .replace.offUp
                                                         : .replace.downUp))
                .font(.system(size: riesig ? (schmal ? 36 : 48)
                                          : (gross ? (schmal ? 24 : 30) : 17),
                              weight: .medium))
                // **Gesperrt heißt gedämpfte Schrift, nicht durchscheinend**
                // (BRAND 5). Vorher `.white.opacity(0.35)`: über einer hellen
                // Szene war das Zeichen dann gar nicht mehr da, über einer
                // dunklen fast normal — die Deckkraft hing am Bild statt am
                // Zustand.
                .foregroundStyle(gedimmt ? Stil.schriftSehrLeise : Color.white)
                // Diskreter Effekt aus SF Symbols: spielt einmal ab und geht
                // von selbst in die Ruhelage zurueck. Ein selbst gerechneter
                // Winkel blieb dagegen stehen.
                // Ein Wert, der sich nie aendert, loest den Effekt nie aus —
                // so bleibt der Knopf bei reduzierter Bewegung still, ohne
                // dass der Zweig die Ansicht austauscht.
                .symbolEffect(.bounce, options: .speed(1.7),
                              value: Stil.bewegungReduziert ? 0 : takt)
                .frame(width: kante(riesig), height: kante(riesig))
                .contentShape(Rectangle())
        }
        // **Jeder Knopf gibt Rückmeldung** (BRAND 5). Zurück, Pause und Vor
        // hatten keine: ein Bildknopf im Standardstil zeigt beim Druck nichts,
        // und gerade hier ist die Fläche groß und der Finger weit vom Symbol.
        .buttonStyle(Stil.Druckknopf())
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
            // Mittel, wie das Absetzen des Reglers: ein Abschnitt zu
            // ueberspringen versetzt den Film um Minuten, nicht um Sekunden.
            Stil.ruck(.mittel)
            // Wie ein Sprung von Hand: Stelle setzen, springen, und die
            // Anzeige kurz nicht überschreiben lassen.
            if inGruppe { gemeinsam.bitteSpringen(auf: nach) }
            else { surface?.seek(toSeconds: nach) }
            gesprungen(auf: nach)
            ausblendenVerschieben()
        case .naechsteFolge:
            // Leicht: ein Tick, dass der Druck angekommen ist — der Wechsel
            // selbst ist dann deutlich genug zu sehen.
            Stil.ruck(.leicht)
            if let naechsteFolge { zurNaechstenFolge(naechsteFolge) }
        }
    }

    // MARK: - Aktionen

    /// Befehle aus dem Jellyfin-Dashboard.
    private func ausfuehren(_ befehl: Fernbefehl) {
        if inGruppe {
            switch befehl {
            case .pause:  if laeuft { gemeinsam.bitteUmschalten(laeuftGerade: true) }
            case .weiter: if !laeuft { gemeinsam.bitteUmschalten(laeuftGerade: false) }
            case .umschalten: gemeinsam.bitteUmschalten(laeuftGerade: laeuft)
            case .stopp: schliessen()
            case let .springenAuf(sekunden): gemeinsam.bitteSpringen(auf: sekunden)
            case .vor: spulen(Int32(model.vorSekunden))
            case .zurueck: spulen(Int32(-model.zurueckSekunden))
            case .naechste, .vorige: break
            }
            steuerungSichtbar = true
            ausblendenVerschieben()
            return
        }
        switch befehl {
        case .pause:
            surface?.pause()
            withAnimation(Stil.umschalten) { laeuft = false }
        case .weiter:
            fortsetzen()
            withAnimation(Stil.umschalten) { laeuft = true }
        case .umschalten:
            if laeuft { surface?.pause() } else { fortsetzen() }
            withAnimation(Stil.umschalten) { laeuft.toggle() }
        case .stopp:
            // **Ein anderes Gerät übernimmt** (Hinweis kam kurz vorher): das
            // Bild geht als Karte ab. Sonst — Dashboard, andere App — wie immer.
            if let ziel = model.uebergabeZielNehmen(), let flaeche = surface {
                abgeben(an: ziel, flaeche: flaeche)
            } else {
                surface?.stop()
                schliessen()
            }
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
        // Dieselbe Rolle wie in `ausfuehren`, also derselbe Token: Umschalten
        // 0,10. Vorher easeOut 0,12 — zwei Werte für ein Umschalten.
        withAnimation(Stil.umschalten) { laeuft = an }
        steuerungSichtbar = true
        zentrale.standNachziehen(position: position, laeuft: an, tempo: tempo)
        ausblendenVerschieben()
        // Gemeldet wird an VLCs Rueckmeldung (`laeuftGemeldet`), nicht hier.
    }

    /// Weiterspielen auf Wunsch des Zuschauers — nach langer Pause ein
    /// Stück zurück (``Pausenruecksprung``). Die Anzeige übernimmt das Ziel
    /// im selben Moment, damit die Leiste nicht erst die alte Stelle zeigt.
    private func fortsetzen() {
        guard let ziel = surface?.resume(ruecksprung: !inGruppe) else { return }
        gesprungen(auf: ziel)
    }

    private func spielenUmschalten() {
        if inGruppe {
            gemeinsam.bitteUmschalten(laeuftGerade: laeuft)
            steuerungSichtbar = true
            ausblendenVerschieben()
            return
        }
        // Kein `laeuft.toggle()` mehr: der Knopf wartet auf VLCs Meldung.
        // Siehe `laeuftGemeldet` oben.
        if laeuft { surface?.pause() } else { fortsetzen() }
        steuerungSichtbar = true
        zentrale.standNachziehen(position: position, laeuft: laeuft, tempo: tempo)
        ausblendenVerschieben()
        // Hier stand `meldeFortschritt()` und las `laeuft` vor VLCs
        // Rueckmeldung: Pause ging als „laeuft" hinaus (T1-N1). Gemeldet wird
        // jetzt an `laeuftGemeldet`.
    }

    private func spulen(_ sekunden: Int32) {
        // Knopf **und** Doppeltipp laufen hier durch, also sitzt die
        // Rueckmeldung an einer Stelle. Leicht, nicht mittel: ein Sprung von
        // zehn Sekunden ist kleiner als das Absetzen des Reglers, und der
        // Doppeltipp wird oft mehrmals hintereinander ausgeloest.
        Stil.ruck(.leicht)
        // Das Ziel vor dem Sprung ausrechnen: von einem noch offenen Ziel aus,
        // nicht von der Stelle, an der VLC gerade noch steht.
        let ziel = Wiedergabetakt.ziel(um: Double(sekunden), stand: anzeigestand)
        if inGruppe {
            // Bitte an die Gruppe; gesprungen wird, wenn der Befehl kommt.
            gemeinsam.bitteSpringen(auf: max(0, ziel))
        } else {
            surface?.jump(seconds: sekunden)
        }
        gesprungen(auf: ziel)
        if sekunden < 0 { taktZurueck += 1 } else { taktVor += 1 }
        // **Mehrfach getippt, zählt sie hoch**: +10 s, +20 s, +30 s — solange
        // die Anzeige der vorigen Sprünge in dieselbe Richtung noch steht.
        let richtung = sekunden < 0 ? -1 : 1
        let bisher = sprungAnzeige.flatMap { $0.richtung == richtung ? $0.sekunden : nil } ?? 0
        sprungAnzeige = (richtung, bisher + Int(abs(sekunden)))
        sprungAnzeigeAufgabe?.cancel()
        sprungAnzeigeAufgabe = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
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
        // Ein Sprung in den Abspann oder ans Ende: der Countdown der Karte
        // fängt von vorn an (gemeldet 26.09.: ans Ende gespult, sofort weiter).
        ebene.gesprungen()
        if countdownAnteil != nil { fuellungsuhr = Fuellungsuhr() }
        angebotNachziehen(vergangen: 0)
        #if DEBUG
        if Sprunglauf.an || Offlinelauf.an { Protokoll.schreib("[Sprung] Anzeige \(String(format: "%.1f", position)) · Angebot \(angebot)") }
        #endif
    }

    /// Die Einblendung an die angezeigte Stelle anpassen. Mit `vergangen: 0`
    /// direkt nach einem Sprung, sonst einmal je Takt.
    ///
    /// - Returns: `true`, wenn der Countdown jetzt abgelaufen ist.
    @discardableResult
    private func angebotNachziehen(vergangen: Double) -> Bool {
        guard !wechselt else { return false }
        var neu = ebene
        let fertig = neu.takt(angebot: angebot,
                                karteFaellig: Abschnittslogik.karteFaellig(position: position, dauer: dauer,
                                                                           abschnitte: abschnitte,
                                                                           hatNaechsteFolge: naechsteFolge != nil,
                                                                           restfenster: Folgenkarte.restfenster),
                                laeuft: laeuft && bildFrei && !amSchieben,
                                vergangen: vergangen,
                                countdown: Abschnittslogik.countdown(position: position, dauer: dauer,
                                                                     abschnitte: abschnitte,
                                                                     restfenster: Folgenkarte.restfenster),
                                // Am Dateiende zählt der Countdown weiter.
                                amEnde: Folgenende.amEnde(position: position, dauer: dauer) && !amSchieben)
        // Blendet der Überspringen-Knopf von selbst aus (`knopfdauer`), soll
        // er so weich gehen, wie er kam: der Takt läuft ohne Animation, also
        // den Wechsel der Sichtbarkeit hier ausdrücklich animieren.
        if neu.anzeige.sichtbar != ebene.anzeige.sichtbar {
            withAnimation(.smooth(duration: 0.34)) { ebene = neu }
        } else {
            ebene = neu
        }
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
    /// - Parameter ab: Startstelle — aus der Folgenliste die Fortsetzstelle,
    ///   beim Weiterschalten immer der Anfang.
    /// Direct Play oder Obergrenze — nur, wenn vom Server gespielt wird.
    ///
    /// **Und nicht in einer Gruppe.** Der Wechsel lädt den Titel neu und
    /// meldet Stopp und Start an den Server — an der Gruppe vorbei: sie
    /// erfährt nichts davon, und man selbst läuft danach allein an der alten
    /// Stelle weiter. Wie beim Weiterschalten zur nächsten Folge bleibt die
    /// Wahl deshalb in der Gruppe weg.
    private var qualitaetswahl: Qualitaetswahl? {
        guard model.downloads.datei(fuer: item.id) == nil, model.umwandelnErlaubt,
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
            Protokoll.schreib("[Qualität] \(model.immerDirectPlay ? "Direct Play" : "\(model.bitratenGrenze) Mbit/s") — neu laden bei \(Int(position)) s")
            // Derselbe Weg wie beim Folgenwechsel: neuer Plan, gleiche Stelle.
            ebeneSchliessen()
            // Ein vorbereiteter Plan der nächsten Folge trägt die alte Wahl.
            vorbereitung.vergessen()
            qualitaetGewechselt = true
            zurNaechstenFolge(item, ab: position)
        }
    }

    private func zurNaechstenFolge(_ folge: Item, ab: Double = 0, ausKarte: Bool = false) {
        guard !wechselt else { return }
        wechselt = true
        // **Aus der Karte: sie zoomt aufs ganze Bild** und deckt den Wechsel.
        // Nicht in der Gruppe, nicht unter AirPlay, nicht bei derselben Folge
        // (Qualitätswahl).
        let zoomt = ausKarte && !inGruppe && airplayPlan == nil && folge.id != item.id
        if zoomt {
            kartenfolge = folge
            kartenuhr = fuellungsuhr
            kartenwechsel = Kartenwechsel(folgeID: folge.id)
            Protokoll.schreib("[Karte] Start → \(folge.id)")
            withAnimation(Self.feder(Folgenkarte.zoomOmega)) { kartenzoom = 1 }
            if let beginn = kartenwechsel?.beginn { Task { await karteWachen(beginn) } }
        }
        let tauschAb = zoomt ? Date().addingTimeInterval(Folgenkarte.tausch) : nil
        model.fertigGeschaut(position: position, dauer: dauer)
        let alt = (item: item, plan: plan, stelle: position)
        // In den letzten Minuten schon geholt (``Folgenvorbereitung``)? Dann
        // wartet der Wechsel nicht noch einmal auf den Server.
        let vorbereitet = vorbereitung.nimm(folge.id)
        // Beginn und erstes Bild ins Protokoll — daraus liest sich die
        // Wechselzeit, mit und ohne Vorbereitung.
        wechselBeginn = Date()
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
            guard ergebnis == .gewechselt else {
                if kartenwechsel != nil { karteZurueck() }
                return
            }
            // Aus der Karte bleibt die Steuerung zu — das Bild übernimmt.
            if kartenwechsel == nil {
                steuerungSichtbar = true
                ausblendenVerschieben()
            }
            await nachschlagen(fuer: folge)
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

    /// Die Karte unten rechts — im Baum, solange es eine nächste Folge gibt,
    /// damit Herein und Hinaus Federn aus dem jetzigen Stand sind.
    @ViewBuilder
    private var kartenebene: some View {
        if let folge = kartenfolge ?? naechsteFolge, !inGruppe {
            Folgenkartenansicht(
                folge: folge,
                bildAdresse: model.imageURL(for: folge, maxHeight: 1080)
                    ?? model.querbildURL(for: folge, breite: 1920),
                pad: mass.pad, seite: mass.seite,
                da: karteDa, zoom: kartenzoom,
                angabenDa: karteDa && kartenwechsel == nil,
                bild: kartenbild,
                fuellung: kartenuhr ?? fuellungsuhr,
                rest: ebene.countdownRest,
                tippen: {
                    Stil.ruck(.leicht)
                    ebene.gedrueckt()
                    zurNaechstenFolge(folge, ausKarte: true)
                },
                abbrechen: {
                    // Abspann ansehen: Countdown weg, am Dateiende kein
                    // Weiterschalten mehr (`Angebotsebene.weiterAbgesagt`).
                    Stil.ruck(.leicht)
                    ebene.schliessen()
                    fuellungStellen()
                })
            .allowsHitTesting(karteDa && kartenwechsel == nil)
            .animation(karteDa ? Self.feder(Folgenkarte.erscheinenOmega)
                                .delay(kartenwechsel == nil ? Folgenkarte.erscheinenVerzug : 0)
                               : Self.feder(Folgenkarte.wegOmega),
                       value: karteDa)
        }
    }

    /// Die neue Folge übernehmen — alles, was der alten gehörte, zurück.
    ///
    /// **Der eine Ort, an dem alt zu neu wird.** Jeder Wechsel — Karte,
    /// Countdown, Ende der Folge, Folgenliste, Sperrbildschirm — kommt über
    /// `zurNaechstenFolge` und `Folgenwechsel` hier an, mit fertigem Plan.
    /// Ein Übergang zwischen den Folgen hängt sich hier ein: davor steht
    /// noch das alte Bild, mit `play` beginnt das neue.
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
        surface?.verzoegerungFuerNeuenTitel(alterTitel: item.id, alteSerie: item.seriesId,
                                            neuerTitel: folge.id, neueSerie: folge.seriesId)
        item = folge
        plan = neuerPlan
        // Grenze gewählt, aber es läuft das Original: entweder reicht die Datei
        // schon, oder der Server wandelt nicht um. Sagen statt schweigen.
        if qualitaetGewechselt {
            qualitaetGewechselt = false
            if !model.immerDirectPlay, neuerPlan.method == .directPlay {
                hinweis = String(localized: "Läuft in Originalqualität. Der Server wandelt nichts um.")
            }
        }
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
        // **Mitten in der Folge anfangen ist ein Sprung.** Die Anzeige steht
        // gleich auf der Startstelle und hält sie, bis VLC dort ist — sonst
        // nähme sie die Zeit der alten Folge oder die Wechselsperre hielte
        // sie auf null. Die Schleife setzt dasselbe nach ihrem Neuanfang.
        if ab > 0 {
            position = ab
            sprung = Wiedergabetakt.Sprung(ziel: ab)
            startNachWechsel = ab
        }
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
        surface?.spurwunsch = spurwunsch(folge, neuerPlan)
        surface?.play(url: neuerPlan.url, abSekunden: ab, container: neuerPlan.container,
                      untertitel: model.untertiteldateien(neuerPlan),
                      softwareDekoder: neuerPlan.softwareDekoder)
    }

    /// Nächste Folge und Abschnitte zum laufenden Titel — beim Öffnen und
    /// nach jedem Wechsel. Ein Ergebnis, das zu spät für seinen Titel kommt,
    /// verwirft `Folgenwechsel.nachschlagen`.
    private func nachschlagen(fuer titel: Item) async {
        // **In der Gruppe keine nächste Folge.** Jeder schaltete sonst für
        // sich weiter, und die Gruppe liefe auseinander.
        await folgenwechsel.nachschlagen(holen: { await model.folgeNach(titel) },
                                         uebernehmen: { naechsteFolge = gemeinsamAn ? nil : $0 })
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
            airplayAufgabe?.cancel()
            airplayAufgabe = Task {
                do {
                    let ergebnis = try await client.airplayPlan(for: item.id, quelle: quelle)
                    guard !Task.isCancelled else { return }
                    switch ergebnis {
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
                    guard !Task.isCancelled else { return }
                    hinweis = error.localizedDescription
                }
            }
        } else {
            airplayAufgabe?.cancel()
            airplayAufgabe = nil
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
            if gemeinsamAn { brueckeNachziehen() }

            // **Dazwischen nur die Zeit** (17.09.2026): im halben
            // Sekundentakt lief sie nach dem Abspielen verzögert an und zählte
            // ungleichmäßig. Dieselben Sperren wie im ganzen Takt.
            nurZeit.toggle()
            if nurZeit {
                guard !wechselt else { continue }
                // **Nur, wenn jemand die Zeit sieht** (28.09.2026, Akku).
                // `position` ist `@State`; jede Zuweisung baut den ganzen
                // Player neu auf und legt neue Zeitzeilen in die unsichtbare
                // Steuerung. Bei ausgeblendeter Steuerung zeigt nichts die
                // halbe Sekunde, also bleibt es beim ganzen Takt — halb so
                // viele Neuaufbauten, den ganzen Film lang. Ein offener
                // Sprung läuft weiter im halben Takt.
                guard zeitSichtbar || sprung != nil else { continue }
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
                // Aus der Folgenliste mitten in eine Folge: siehe `folgeAnwenden`.
                if let ab = startNachWechsel {
                    startNachWechsel = nil
                    stand.nachWechsel = false
                    stand.position = ab
                    stand.sprung = Wiedergabetakt.Sprung(ziel: ab)
                }
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
                Startmessung.geteilt.marke("Ladeschirm weicht")
                if let beginn = wechselBeginn {
                    wechselBeginn = nil
                    Protokoll.schreib("[Wechsel] erstes Bild nach \(Int(Date().timeIntervalSince(beginn) * 1000)) ms")
                }
                if let k = kartenwechsel, k.bildSeit == nil {
                    kartenwechsel?.bildSeit = k.seit
                    Protokoll.schreib("[Karte] erstes Bild nach \(Int(k.seit * 1000)) ms")
                    Task { await karteUebergeben() }
                }
                withAnimation(.easeOut(duration: 0.3)) { erstesBildDa = true } completion: {
                    Startmessung.geteilt.marke("Ladeschirm ausgeblendet")
                }
                // Aus einer Übergabe: die Karte zoomt jetzt aufs Bild.
                Uebergabebuehne.geteilt.bildDa(item.id)
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
            let karteVorher = karteDa
            if angebotNachziehen(vergangen: Wiedergabetakt.taktlaenge / .seconds(1)),
               let folge = naechsteFolge {
                Protokoll.schreib("[Karte] Countdown abgelaufen")
                zurNaechstenFolge(folge, ausKarte: karteVorher)
            }
            #if DEBUG
            if Sprunglauf.an || Offlinelauf.an { sprungtaktSchreiben(vlc: surface.positionSeconds) }
            #endif

            // **Die nächste Folge vorbereiten**, solange diese noch läuft —
            // nicht in der Gruppe, die schaltet selbst. Einmal je Folge;
            // wann und über welches Netz, sagt `Vorpuffer`.
            if let folge = naechsteFolge, !inGruppe, !wechselt,
               Vorpuffer.jetzt(position: position, dauer: dauer,
                               abspannVon: abschnitte.first { $0.art == .abspann }?.von,
                               netzGuenstig: vorbereitung.netzGuenstig),
               vorpufferErlaubt {
                vorbereitung.vorbereiten(folge) { await model.plan(for: folge.id, still: true) }
            }

            // Am Ende von selbst weiter — nur mit Karte (Abspann-Abschnitt vom
            // Server), und nicht, wenn sie abgesagt wurde. Der Schalter
            // „Nächste Folge automatisch" spielt dafür keine Rolle mehr
            // (17.09.2026).
            // **Zählt die Karte, gehört das Weiterschalten ihr** (26.09.: ans
            // Ende gespult, und `position >= dauer - 1` wechselte sofort).
            if ebene.weiterAmEnde, let folge = naechsteFolge, !wechselt,
               Folgenende.weiterschalten(position: position, dauer: dauer,
                                         seitOeffnen: Date().timeIntervalSince(seitStart),
                                         karteZaehlt: ebene.karteZaehlt) {
                Protokoll.schreib("[Wechsel] Dateiende ohne Karte")
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
            abspielen:   inGruppe ? { gemeinsam.bitteUmschalten(laeuftGerade: false) }
                                  : { fortsetzen(); laufzustand(true) },
            anhalten:    inGruppe ? { gemeinsam.bitteUmschalten(laeuftGerade: true) }
                                  : { surface?.pause();  laufzustand(false) },
            umschalten:  { spielenUmschalten() },
            springenAuf: inGruppe ? { ziel in gemeinsam.bitteSpringen(auf: ziel); gesprungen(auf: ziel) }
                                  : { ziel in surface?.seek(toSeconds: ziel); gesprungen(auf: ziel) },
            vor:         { spulen(Int32(model.vorSekunden)) },
            zurueck:     { spulen(Int32(-model.zurueckSekunden)) },
            naechste:    inGruppe ? nil : naechsteFolge.map { folge in { zurNaechstenFolge(folge) } }))
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
                // Siehe den Knopf oben: bei reduzierter Bewegung bleibt der
                // Wert stehen, und der Effekt spielt nicht.
                .symbolEffect(.bounce, options: .speed(1.7),
                              value: Stil.bewegungReduziert ? false : gedreht)
            // Vorher `.footnote.weight(.medium)` — dieselbe Stufe (13 Medium),
            // aber als Systemgrad, der mit der Systemschrift mitwandert; der
            // Player bleibt fest.
            // Mit Vorzeichen, weil sie hochzählt: +10 s, +20 s, +30 s.
            Group {
                if richtung < 0 { Text("−\(sekunden) s") } else { Text("+\(sekunden) s") }
            }
            .font(Stil.kachel)
            .monospacedDigit()
        }
        // Vorher rohes `.white`.
        .foregroundStyle(Stil.schrift)
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
    /// Gleich mit Software-Dekoder öffnen — ``PlaybackPlan/softwareDekoder``.
    var softwareDekoder = false
    /// Die gewünschten Spuren, ebenfalls vor `play`.
    var spuren: VLCPlayerView.Spurwunsch?
    let onCreate: (VLCPlayerView) -> Void

    func makeUIView(context: Context) -> VLCPlayerView {
        let view = VLCPlayerView()
        // Vor dem Start setzen, nicht danach: die Optionen haengen am Medium,
        // und das entsteht in `play`.
        view.puffer = puffer
        view.spurwunsch = spuren
        view.play(url: url, abSekunden: startAt, container: container, untertitel: untertitel,
                  softwareDekoder: softwareDekoder)
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
    /// Wie weit die Baender reichen. Oben deckt es Statusleiste, Titel,
    /// Metazeile und die Knopfreihe; unten die Ueberspringen-Pille, die
    /// Zeitzeile und den sicheren Bereich darunter.
    private static let hoeheOben: CGFloat = 200
    private static let hoeheUnten: CGFloat = 260

    var body: some View {
        // **Reines Schwarz, nicht `Stil.grund`.** Ueber HDR-Video wird #0B0B0D
        // als SDR-Farbe hochgerechnet und hebt dunkle Szenen an — die
        // Steuerung machte das Bild heller statt dunkler. Wie auf tvOS, und so
        // steht es in BRAND 4.
        // **Die Flaeche fuehrt die Groesse, die Baender liegen darueber.**
        //
        // Hier stand ein `ZStack` mit einem `VStack` darin, und dessen zwei
        // feste Baender ergaben zusammen **460 Punkt Mindesthoehe**. Vorher
        // war der Schleier ein blosses `Color` — das hat keine eigene Groesse
        // und passt in jeden Rahmen, auch in den kleinen Fensterplayer. Mit
        // der Mindesthoehe ragte er dort heraus, und mit ihm alles, was auf
        // ihm liegt. Rückmeldung vom 21.09.: „der Player ist kaputt, die Elemente
        // ragen aus dem Player raus."
        //
        // Als `overlay` auf der Flaeche zaehlen die Baender fuer die Groesse
        // nicht mit — die Flaeche bleibt beliebig dehnbar —, und `clipped()`
        // haelt sie in ihrem Rahmen, wenn der einmal kleiner ist als sie.
        Color.black.opacity(0.45)
            .overlay(alignment: .top) { bandOben }
            .overlay(alignment: .bottom) { bandUnten }
            .clipped()
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    /// Oben: gehalten, bis die Knopfreihe zu Ende ist, dann ausgefedert. Ein
    /// Verlauf, der gleich am oberen Rand abnimmt, ist genau dort am
    /// schwaechsten, wo der Titel steht — 0,55 ueber der Flaeche sind zusammen
    /// 0,752, und damit traegt der Titel 9,68:1 und die Metazeile in
    /// `schriftLeise` 4,66:1.
    private var bandOben: some View {
        LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                               .init(color: .black.opacity(0.55), location: 0.45),
                               .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: Self.hoeheOben)
    }

    /// Unten umgekehrt und am Rand am dichtesten: dort sitzt die Zeitzeile.
    /// 0,62 ueber der Flaeche sind zusammen 0,791 — 11,27:1 statt der 5,70:1,
    /// die die flache Fassung erreichte. Der Rand ist also **lesbarer**
    /// geworden, nicht nur die Mitte heller.
    private var bandUnten: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0),
                               .init(color: .black.opacity(0.42), location: 0.55),
                               .init(color: .black.opacity(0.62), location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: Self.hoeheUnten)
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
    let amSchieben: Bool
    let schrift: CGFloat
    let pad: Bool
    /// Das Trickplay-Bild zur Stelle, oder `nil`.
    let vorschau: (Double) -> CGImage?
    /// Grenzen der Abschnitte in Sekunden — Kerben auf dem Regler.
    let marken: [Double]
    /// `true` beim Anfassen, `false` beim Loslassen.
    let schiebt: (Bool) -> Void

    var body: some View {
        HStack(spacing: 14) {
            // Die beiden Zeiten sagt der Regler schon („12 Minuten von 45
            // Minuten"); als Ziffern mit Doppelpunkt las VoiceOver sie ein
            // zweites Mal, und schlechter.
            Text(Spielzeit.text(position))
                .accessibilityHidden(true)
            Zeitregler(wert: $position, bis: max(dauer, 1), marken: marken,
                       beimSchieben: schiebt)
                .overlay(alignment: .topLeading) {
                    if amSchieben { vorschauKasten }
                }
            restzeit
        }
        .font(.system(size: schrift).monospacedDigit())
        // **`schriftLeise` ist hier nicht zu retten.** Die Zeile liegt mit 13
        // Punkt auf dem Playerschleier über dem laufenden Bild: über einer
        // weißen Szene trug `schriftLeise` 1,34:1, Grenze 4,5. Unter dem
        // Verlaufsband am Fuß (zusammen 0,791) kommt `schrift` auf 11,27:1 —
        // Verstrichene Zeit und Restzeit sind keine Nebensache; sie sind der
        // Grund, aus dem man hier hinsieht.
        .foregroundStyle(Stil.schrift)
    }

    /// **Restzeit oder Ende — ein Tipp schaltet um** (1.0.5, zum
    /// Ausprobieren). „−12:34" oder „Endet um 22:41"; die Wahl bleibt. Kein
    /// eigener Knopf, keine zweite Zeile: dieselbe Stelle, dieselbe Schrift.
    @AppStorage("restzeitAlsEnde") private var alsEnde = false

    private var restzeit: some View {
        let rest = max(dauer - position, 0)
        return Button {
            alsEnde.toggle()
        } label: {
            Group {
                if alsEnde {
                    Text("Endet um \(Date().addingTimeInterval(rest).formatted(date: .omitted, time: .shortened))")
                } else {
                    Text(verbatim: "−" + Spielzeit.text(rest))
                }
            }
            .lineLimit(1)
            .contentShape(Rectangle().inset(by: -10))
        }
        .buttonStyle(.plain)
        // Für VoiceOver ein Schalter mit Zustand — die Zeit selbst liest der
        // Regler schon vor.
        .accessibilityLabel(alsEnde ? Text("Endet um \(Date().addingTimeInterval(rest).formatted(date: .omitted, time: .shortened))")
                                    : Text("Restzeit"))
        .accessibilityHint(Text("Wechselt zwischen Restzeit und Ende"))
    }

    /// **Über dem Griff: Vorschaubild, darunter die Zeit.** Ohne Trickplay
    /// am Server nur die Zeit — kein leerer Kasten.
    private var vorschauKasten: some View {
        GeometryReader { g in
            let bild = vorschau(position)
            let breite: CGFloat = pad ? 200 : 160
            let hoehe = breite * 9 / 16
            let anteil = dauer > 0 ? min(max(position / dauer, 0), 1) : 0
            // Am Rand bleibt der Kasten ganz auf der Leiste stehen.
            let halb = (bild == nil ? 40 : breite / 2)
            let x = min(max(g.size.width * anteil, halb), max(g.size.width - halb, halb))
            VStack(spacing: 6) {
                if let bild {
                    Image(decorative: bild, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: breite, height: hoehe)
                        .clipShape(RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous))
                        // Ränder trägt `Stil.rand`. Vorher weiß 35 % — eine
                        // zweite Zahl für dieselbe Rolle.
                        .overlay(RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous)
                            .strokeBorder(Stil.rand, lineWidth: 1))
                }
                Text(Spielzeit.text(position))
                    // Bold trägt allein der Seitentitel (BRAND 2), hier also
                    // Semibold. Der Grad bleibt `mass.zeit`: er rechnet mit der
                    // Fenstergröße.
                    .font(.system(size: schrift, weight: .semibold).monospacedDigit())
                    // Vorher rohes `.white`.
                    .foregroundStyle(Stil.schrift)
                    // **Eine eigene Fläche, weil hier kein Schleier liegt.**
                    // Die Zeit stand blank über dem Trickplay-Standbild: über
                    // einem weißen Bild 1,09:1, Grenze 4,5. Auf `Stil.grund`
                    // mit 0,82 — dieselbe Deckkraft wie am Technikschild —
                    // sind es 10,93:1, und zwar über jedem Standbild.
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Stil.grund.opacity(0.82)))
            }
            .fixedSize()
            // Unterkante knapp über der Trefferfläche — die Leiste selbst
            // liegt in deren Mitte.
            // `schrift + 6`: die Kapsel um die Zeit trägt oben und unten je
            // 3 Punkt Luft. Ohne die 6 rutschte der Kasten um 3 Punkt nach
            // unten — die Unterkante soll bleiben, wo sie abgenommen ist.
            .position(x: x, y: -((bild == nil ? 0 : hoehe + 6) + schrift + 6) / 2 - 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
    /// Schrift auf der weißen Pille — der Grund des Players, #0B0B0D.
    private static let dunkel = Stil.grund
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
                // **Weiße Pille mit dem Überspringen-Zeichen** (Dreieck und
                // Strich) — für beide Angebote, wie im Entwurf.
                HStack(spacing: 8) {
                    Image(systemName: "forward.end.fill")
                    Text(verbatim: angebot.beschriftung)
                }
                // Vorher 15 Bold — Bold steht genau einmal, am Seitentitel
                // (BRAND 2). Die Stufe darunter ist 15 Semibold.
                .font(Stil.listentitel)
                .padding(.horizontal, 18)
                .frame(height: 40)
                .background {
                    ZStack(alignment: .leading) {
                        // Die eine gefüllte Fläche im Bild ist der Hauptknopf,
                        // und seine Farbe ist `schrift` (BRAND 7). Vorher rohes
                        // `.white`.
                        RoundedRectangle(cornerRadius: Stil.eckeFeld, style: .continuous).fill(Stil.schrift)
                        if let fuellung {
                            // **Durchgehend statt im Takt** (17.09.2026):
                            // im halben Sekundentakt nachgezogen ruckelte sie am
                            // Anfang und gegen Ende. **Dunkel auf Weiß**, nicht in
                            // Akzentfarbe: die gehört im Player allein dem Griff
                            // der Leiste beim Spulen.
                            TimelineView(.animation) { zeit in
                                GeometryReader { g in
                                    Rectangle()
                                        .fill(Self.dunkel.opacity(0.16))
                                        .frame(width: g.size.width * fuellung.anteil(jetzt: zeit.date))
                                }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Stil.eckeFeld, style: .continuous))
                }
            }
            .buttonStyle(Stil.Druckknopf())
            .foregroundStyle(Self.dunkel)
            .fixedSize()
            .accessibilityLabel(Text(verbatim: angebot.beschriftung))
            .accessibilityValue(fuellung.map {
                _ in Text("Startet in \(rest) Sekunden")
            } ?? Text(verbatim: ""))
        }
    }
}
