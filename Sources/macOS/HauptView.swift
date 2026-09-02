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
    /// Jeder Bereich hat seinen eigenen Stapel — wer zwischen Filmen und
    /// Serien wechselt, findet zurück, wo er war.
    @State private var stapel: [Bereich: NavigationPath] = [:]

    init(model: AppModel) {
        self.model = model
        _steuerung = State(initialValue: Abspielsteuerung(model: model))
    }

    var body: some View {
        HStack(spacing: 0) {
            Seitenleiste(model: model, bereich: $bereich) { schiebe(ProfilRoute()) }

            ZStack {
                Stil.grund
                inhalt
            }
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
        // Der Player nimmt das ganze Fenster ein, Seitenleiste eingeschlossen.
        .overlay {
            if let wunsch = steuerung.wunsch {
                PlayerScreen(model: model, wunsch: wunsch) { steuerung.schliessen() }
                    // Von unten herauf und wieder hinunter — wie auf dem
                    // iPhone. Damit zeigt der Winkel oben links in die
                    // Richtung, in die der Player wirklich verschwindet.
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(Stil.zeitSprung, value: steuerung.wunsch?.id)
        .onReceive(NotificationCenter.default.publisher(for: Kommandopost.name)) { post in
            guard let kommando = Kommandopost.empfangen(post) else { return }
            ausfuehren(kommando)
        }
    }

    private var inhalt: some View {
        NavigationStack(path: pfad(bereich)) {
            Group {
                switch bereich {
                case .start:  HomeView(model: model) { schiebe($0) }
                case .filme:  BibliothekView(model: model, art: "movies", titel: "Filme")
                case .serien: BibliothekView(model: model, art: "tvshows", titel: "Serien")
                case .suche:  SucheView(model: model)
                }
            }
            .navigationDestination(for: Item.self) { titel in
                DetailView(model: model, item: titel) { zurueck() }
            }
            .navigationDestination(for: ProfilRoute.self) { _ in
                ProfilView(model: model) { zurueck() }
            }
            .navigationDestination(for: EinstellungenRoute.self) { _ in
                EinstellungenView(model: model) { zurueck() }
            }
            .navigationDestination(for: WiedergabeRoute.self) { _ in
                WiedergabeEinstellungenView(model: model) { zurueck() }
            }
            .navigationDestination(for: QuickConnectRoute.self) { _ in
                QuickConnectView(model: model) { zurueck() }
            }
        }
        // **Ohne Systemleiste.** `NavigationStack` setzt auf dem Mac von sich
        // aus einen Zurückpfeil in die Titelleiste — als Glasknopf, neben die
        // Fensterampel, die er dabei verschiebt. Auf jeder anderen Plattform
        // sitzt der Weg zurück als eigener Pfeil **im Bild** (E9).
        .toolbar(.hidden)
        .toolbarBackground(.hidden, for: .windowToolbar)
        // Der Stapel gehört zum Bereich; ohne die Kennung baut SwiftUI ihn
        // beim Wechsel nicht neu auf und zeigt die alte Seite weiter.
        .id(bereich)
    }

    private func pfad(_ b: Bereich) -> Binding<NavigationPath> {
        Binding(get: { stapel[b] ?? NavigationPath() },
                set: { stapel[b] = $0 })
    }

    /// Ein Ziel auf den Stapel des sichtbaren Bereichs legen.
    private func schiebe(_ ziel: some Hashable) {
        var p = stapel[bereich] ?? NavigationPath()
        p.append(ziel)
        stapel[bereich] = p
    }

    /// Eine Ebene zurück im Stapel des sichtbaren Bereichs.
    private func zurueck() {
        var p = stapel[bereich] ?? NavigationPath()
        guard !p.isEmpty else { return }
        p.removeLast()
        stapel[bereich] = p
    }

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
        .background(Stil.flaeche)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Stil.linie).frame(width: 1)
        }
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

