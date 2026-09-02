import JellyfinKit
import SwiftUI

/// Welchen Bereich die Seitenleiste zeigt. Dieselben vier wie in der Leiste
/// unten auf dem iPhone.
enum Bereich: String, Hashable, CaseIterable {
    case start, filme, serien, suche

    var symbol: String {
        switch self {
        case .start:  "house"
        case .filme:  "film"
        case .serien: "tv"
        case .suche:  "magnifyingglass"
        }
    }

    var beschriftung: LocalizedStringKey {
        switch self {
        case .start:  "Start"
        case .filme:  "Filme"
        case .serien: "Serien"
        case .suche:  "Suche"
        }
    }
}

/// Das Fenster: Seitenleiste links, Inhalt rechts.
///
/// Die Leiste unten des iPhones wandert hier an die Seite. Der Grund ist
/// nicht Geschmack: unten lag sie in Daumenreichweite, und sie setzte eine
/// feste Bildschirmhöhe voraus. Beides gibt es in einem Fenster nicht.
struct HauptView: View {
    let model: AppModel

    @State private var bereich: Bereich = .start
    @State private var steuerung: Abspielsteuerung
    @State private var navigator = Navigator()

    init(model: AppModel) {
        self.model = model
        _steuerung = State(initialValue: Abspielsteuerung(model: model))
    }

    var body: some View {
        HStack(spacing: 0) {
            Seitenleiste(model: model, bereich: $bereich) {
                navigator.oeffne(.profil, in: bereich)
            }
            // **Der Sicherheitsrand der Titelleiste gilt links genauso wenig
            // wie rechts.** Vorher hielt nur der Inhaltsbereich ihn nicht
            // ein; die Leiste stand deshalb rund dreissig Punkt tiefer als
            // das Fenster — samt ihrer Fläche und ihrer Kante. Dazu kam, dass
            // sie oben nochmal `ampelHoehe` freihält: der Abstand lag also
            // doppelt an.
            .ignoresSafeArea(.container, edges: .vertical)

            // **Die Kante als eigene Spalte, nicht als Auflage.**
            //
            // Als `.overlay` auf der Leiste hing sie an deren Rahmen und
            // hörte dort auf, wo der Rahmen aufhörte — nicht am Fensterrand.
            // Hier ist sie eine Spalte für sich, volle Höhe, ohne
            // Sicherheitsrand.
            Rectangle()
                .fill(Stil.linie)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .vertical)

            ZStack {
                Stil.grund
                inhalt
            }
            // Der ruhende Elternteil: hier steht die Anweisung, die den
            // Tausch darin führt.
            .animation(Stil.zeitSeite, value: bereich)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // **Der Sicherheitsrand der Titelleiste fällt hier weg, nicht auf
            // jeder Seite einzeln.**
            //
            // Gemessen: die Scrollfläche saß 32 Punkt tief und trug oben
            // einen Rand von 32 — das war die schwarze Leiste. Und sie kam
            // nicht überall an: die Kulisse landete mal bei 0, mal bei 32,
            // was Film- und Serienseite um genau diesen Betrag gegeneinander
            // verschob. Ein Rand, der an mehreren Stellen halb entfernt wird,
            // ist schlimmer als einer, der überall steht.
            //
            // Die Seiten setzen ihren oberen Abstand selbst — `inhaltOben`.
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(Stil.grund)
        .environment(steuerung)
        .environment(navigator)
        .environment(\.bereich, bereich)
        // Der Player nimmt das ganze Fenster ein, Seitenleiste eingeschlossen.
        .overlay {
            if let wunsch = steuerung.wunsch {
                PlayerScreen(model: model, wunsch: wunsch) { steuerung.schliessen() }
                    // Aufsteigen — die dritte der drei Bewegungen. Von unten
                    // herauf und wieder hinunter; deshalb zeigt der Winkel
                    // oben links nach unten.
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(Stil.zeitSprung, value: steuerung.wunsch?.id)
        .onReceive(NotificationCenter.default.publisher(for: Kommandopost.name)) { post in
            guard let kommando = Kommandopost.empfangen(post) else { return }
            ausfuehren(kommando)
        }
    }

    /// Wie viele Seiten **gezeigt** werden. Das ist bewusst nicht dasselbe
    /// wie `navigator.seiten(bereich).count`: beim Tiefergehen hinkt der Wert
    /// ein Einzelbild hinterher, und genau darin liegt der Trick.
    ///
    /// **Warum überhaupt.** Mit `.transition(.move)` legt SwiftUI die neue
    /// Seite an und bewegt sie im selben Einzelbild. In dieses eine Bild
    /// fällt dann der gesamte Aufbau der Detailseite — Kulisse, Kopf,
    /// Besetzung, Ähnliches. Das Bild kommt zu spät, die Bewegung setzt mit
    /// einem Sprung ein, und keine Kurve der Welt bügelt das aus. Ein
    /// `UINavigationController` macht es seit jeher andersherum: die neue
    /// Ansicht kommt in den Behälter, wird ausgelegt, und **erst danach**
    /// startet der Animator.
    ///
    /// Also: Seite anlegen, um eine volle Breite nach rechts versetzt, ein
    /// Bild warten, dann fahren. Beim Zurückgehen entfällt das Warten — dort
    /// steht längst alles.
    /// **Je Bereich getrennt.** Vorher stand hier eine einzige Zahl für alle
    /// vier Bereiche. Wer in „Filme" eine Seite offen ließ und in der Leiste
    /// auf „Start" wechselte, setzte sie damit von 1 auf 0 zurück — und weil
    /// am Elternteil `.animation(zeitSeite, value: bereich)` hängt, lief
    /// dieser Rücksprung als Bewegung ab: die Wurzel fuhr ihren Mitgang
    /// zurück und der Schleier blendete aus. **Das war die komische
    /// Einblendung mit dem dunklen Verlauf beim Leistenwechsel.**
    ///
    /// Der Stapel liegt im `Navigator` seit jeher je Bereich getrennt; diese
    /// Zahl gehört daneben.
    @State private var gezeigteTiefe: [Bereich: Int] = [:]

    /// Wie viele Seiten im **aktuellen** Bereich gezeigt werden.
    private var tiefe: Int { gezeigteTiefe[bereich] ?? 0 }

    private var inhalt: some View {
        GeometryReader { raum in
            let breite = raum.size.width
            // Wie weit die darunterliegende Seite mitgeht. Ein Drittel — so
            // hält es die Systemnavigation, und daher kommt der Eindruck von
            // Ebenen statt von einem Rechteck, das vorbeischiebt.
            let mitgang = -breite * 0.3

            ZStack {
                // Die Wurzel des Bereichs liegt immer unten.
                // **Mitgang und Schleier gehören *unter* die Kennung.**
                //
                // Standen sie darüber, galten sie für die ausscheidende
                // Wurzel genauso wie für die neue — und beide lasen `tiefe`
                // des *neuen* Bereichs. Wer in „Filme" eine Seite offen ließ
                // und auf „Start" wechselte, sah deshalb, wie die alte Wurzel
                // ihren Mitgang zurückfuhr und der Schleier ausblendete: eine
                // Bewegung mit dunklem Verlauf, die dort nichts zu suchen
                // hat. Bei „Filme" und „Serien" fiel es nicht auf, weil dort
                // eine Seite obendrauf lag, die es verdeckte.
                //
                // Unter der Kennung gehören sie zur jeweiligen Wurzel. Die
                // ausscheidende behält ihren Stand und blendet einfach aus.
                wurzel
                    .offset(x: tiefe > 0 ? mitgang : 0)
                    .overlay {
                        Color.black.opacity(tiefe > 0 ? 0.28 : 0)
                            .allowsHitTesting(false)
                    }
                    .id(bereich)
                    .transition(.opacity)
                    // **Die Wurzel liegt ausdrücklich unten.** Ohne feste
                    // Ebenen fuhr die Seite unter den Kacheln der Startseite
                    // herein, und das sah aus wie Durchsichtigkeit.
                    .zIndex(0)

                ForEach(Array(navigator.seiten(bereich).enumerated()), id: \.element.id) { platz, ziel in
                    let obenauf = platz == tiefe - 1
                    let gezeigt = platz < tiefe

                    ZStack {
                        Stil.grund
                        seite(ziel)
                    }
                    // Rechts draußen, bis sie an der Reihe ist; darunter
                    // liegende Seiten gehen ein Stück mit.
                    .offset(x: gezeigt ? (obenauf ? 0 : mitgang) : breite)
                    .overlay {
                        Color.black.opacity(gezeigt && !obenauf ? 0.28 : 0)
                            .allowsHitTesting(false)
                    }
                    // Der Schlagschatten an der Vorderkante. Als schmaler
                    // Verlauf **neben** der Seite, nicht als `.shadow` —
                    // ein Schatten um eine bildschirmgroße Ansicht zwingt
                    // sie in einen eigenen Zwischenspeicher, und den baut
                    // das System in jedem Einzelbild neu auf.
                    .overlay(alignment: .leading) {
                        LinearGradient(colors: [.black.opacity(0.45), .clear],
                                       startPoint: .trailing, endPoint: .leading)
                            .frame(width: 28)
                            .offset(x: -28)
                            .allowsHitTesting(false)
                    }
                    .zIndex(Double(platz + 1))
                    // **Losfahren, sobald die Seite wirklich steht.**
                    //
                    // Vorher wartete hier ein `Task.sleep(16 ms)`. Das war
                    // ein Rennen: ein Einzelbild dauert bei 120 Hz gut acht
                    // Millisekunden, mal lag der Weckruf davor, mal dahinter.
                    // Lag er davor, fielen Anlegen und Losfahren in denselben
                    // Vorgang — dann sprang die Seite ohne Bewegung an ihren
                    // Platz. **Genau das ist „manchmal normal, manchmal
                    // hart".** Es war nie die Kurve.
                    //
                    // `DispatchQueue.main.async` aus `onAppear` heraus läuft
                    // dagegen zugesichert nach dem Abschluss des laufenden
                    // Vorgangs. Kein Wecker, keine Millisekunden, kein Rennen.
                    .onAppear {
                        // Steht die Seite schon, ist das ein Rückkehrer aus
                        // einem Leistenwechsel — der fährt nicht noch einmal.
                        guard platz >= tiefe else { return }
                        // **Nur dieser eine Schreibzugriff.** Vorher stand
                        // daneben ein zweiter, unanimierter (`ruht = false`).
                        // Beides ist Zustand derselben Ansicht und landet in
                        // einem Aktualisierungslauf — für den sucht SwiftUI
                        // sich *eine* Transaktion aus. Fällt die Wahl auf die
                        // leere, wird der Versatz ohne Bewegung gesetzt. Es
                        // war der einzige Ort im Baum, an dem eine laufende
                        // Bewegung überhaupt kippen konnte.
                        DispatchQueue.main.async {
                            withAnimation(Stil.zeitSeitenschub) { gezeigteTiefe[bereich] = platz + 1 }
                        }
                    }
                    // **Nur das Hinausfahren ist ein Übergang.** Das
                    // Hereinfahren macht der Versatz oben, damit die Seite
                    // vorher fertig ausgelegt ist. Blenden tut hier nichts:
                    // unterwegs durchsichtig sieht nach Fehler aus.
                    .transition(.asymmetric(insertion: .identity,
                                            removal: .move(edge: .trailing)))
                }
            }
            // **Sonst tritt die Wurzel über den Rand.** Der Mitgang schiebt
            // sie um ein Drittel nach links — ohne Beschnitt landet dieses
            // Drittel über der Seitenleiste, und man sieht Startseite und
            // Seitenleiste übereinander. Genau das war im Bild zu sehen.
            .clipped()
        }
        .onChange(of: navigator.seiten(bereich).count, initial: true) { alt, neu in
            guard neu != tiefe else { return }
            if neu > alt {
                // Tiefergehen macht die Seite selbst, siehe `onAppear` oben.
            } else {
                // Zurück: `Navigator.zurueck` animiert das Entfernen bereits,
                // der Mitgang muss im selben Zug zurück.
                withAnimation(Stil.zeitSeitenschub) { gezeigteTiefe[bereich] = neu }
            }
        }
    }

    @ViewBuilder
    private var wurzel: some View {
        switch bereich {
        case .start:  HomeView(model: model)
        case .filme:  BibliothekView(model: model, art: "movies", titel: "Filme")
        case .serien: BibliothekView(model: model, art: "tvshows", titel: "Serien")
        case .suche:  SucheView(model: model)
        }
    }

    @ViewBuilder
    private func seite(_ ziel: Seitenziel) -> some View {
        switch ziel {
        case let .titel(item):  DetailView(model: model, item: item) { zurueck() }
        case .profil:           ProfilView(model: model) { zurueck() }
        case .einstellungen:    EinstellungenView(model: model) { zurueck() }
        case .wiedergabe:       WiedergabeEinstellungenView(model: model) { zurueck() }
        case .quickConnect:     QuickConnectView(model: model) { zurueck() }
        }
    }

    private func zurueck() { navigator.zurueck(in: bereich) }

    private func ausfuehren(_ kommando: Kommando) {
        switch kommando {
        case .start:  bereich = .start
        case .filme:  bereich = .filme
        case .serien: bereich = .serien
        case .suche:  bereich = .suche
        case .zurueck:
            zurueck()
        }
    }
}

// MARK: - Seitenleiste

struct Seitenleiste: View {
    let model: AppModel
    @Binding var bereich: Bereich
    let zumProfil: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Platz für die Fensterampel — sie liegt über der Seitenleiste.
            Color.clear.frame(height: Stil.ampelHoehe)

            Wortmarke(hoehe: 28)
                .padding(.horizontal, 20)
                .padding(.bottom, 18)

            VStack(spacing: 2) {
                ForEach(Bereich.allCases, id: \.self) { fall in
                    Seitenleistenzeile(symbol: fall.symbol,
                                       beschriftung: fall.beschriftung,
                                       aktiv: bereich == fall) { bereich = fall }
                }
            }
            .padding(.horizontal, 12)

            if !model.views.isEmpty {
                Seitenleistenrubrik(text: "Bibliotheken")
                    .padding(.horizontal, 12)
                    .padding(.top, 26)
                    .padding(.bottom, 8)
            }

            Spacer(minLength: 0)

            Divider().overlay(Stil.linie)

            // Kein `NavigationLink`: die Seitenleiste liegt **neben** dem
            // Stapel, nicht darin. Sie schiebt das Ziel deshalb selbst auf
            // den Stapel des sichtbaren Bereichs.
            Button { zumProfil() } label: { Profilzeile(model: model) }
                .buttonStyle(.plain)
                .padding(12)
        }
        .frame(width: Stil.seitenleisteBreite)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Stil.flaeche)
        .task { if model.views.isEmpty { await model.loadViews() } }
    }
}

/// Wer angemeldet ist, und wo. Unten in der Seitenleiste — auf dem iPhone
/// sitzt dasselbe oben rechts als Profilzeichen.
struct Profilzeile: View {
    let model: AppModel
    @State private var schwebt = false

    var body: some View {
        HStack(spacing: 10) {
            Profilzeichen(name: model.session?.userName ?? "?",
                              bild: model.benutzerbildURL(groesse: 60), groesse: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: model.session?.userName ?? "—")
                    .font(Stil.kachelTitel)
                    .foregroundStyle(Stil.schrift)
                    .lineLimit(1)
                Text(verbatim: model.serverName ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(schwebt ? Stil.schrift.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: Stil.ecke))
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
    }

}

