import JellyfinKit
import SwiftUI

/// Die Startseite. Reihen mit Hochkant-Postern — was angefangen ist, zuerst.
struct HomeView: View {
    let model: AppModel

    @Environment(\.breit) private var breit
    @Environment(\.fensterknoepfe) private var fensterknoepfe
    @Environment(\.scenePhase) private var lebenslage

    /// Laden und Reihenfolge stehen in `Startseitenmodell` — geteilt mit
    /// der tvOS-Fassung.
    @State private var stand = Startseitenmodell()
    @State private var abspielen: Abspielwunsch?
    @State private var bereitet = false
    /// Keine der Anfragen kam durch.
    @State private var laedtNeu = false
    /// Läuft auf einem anderen Gerät etwas? Siehe ``Uebernahmemodell``.
    @State private var uebernahme = Uebernahmemodell()
    /// Bei mehr als einem Gerät wird gefragt statt geraten.
    @State private var auswahlOffen = false

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()

            inhalt
            kopf

            if !stand.geladen || bereitet {
                Lader()
            } else if stand.weiterschauen.isEmpty, stand.naechsteFolge.isEmpty, stand.zuletzt.isEmpty {
                nichtsDa
            }
        }
        // **Nach dem Zusehen neu holen, ohne Frist.**
        //
        // Wer aus dem Player zurückkommt, hat die Stelle gerade verschoben —
        // „Weiterschauen" ist damit sicher veraltet, und die Folge ist unter
        // Umständen zu Ende und gehört gar nicht mehr in die Reihe.
        // **Nur solange kein Player läuft.** Im Player ist die Kopfzeile weg,
        // und der Server hätte alle zehn Sekunden eine Anfrage mehr zu
        // beantworten, während es aufs Bild ankommt.
        .task(id: abspielen == nil) {
            if abspielen == nil { uebernahme.starten(model) } else { uebernahme.beenden() }
        }
        .onDisappear { uebernahme.beenden() }
        .confirmationDialog("Wo weiterschauen?", isPresented: $auswahlOffen,
                            titleVisibility: .visible) {
            ForEach(uebernahme.angebote) { s in
                Button("\(s.geraetename ?? String(localized: "Gerät")) — \(s.titelzeile)") {
                    hierWeiterschauen(s)
                }
            }
            Button("Abbrechen", role: .cancel) { auswahlOffen = false }
        } message: {
            Text("Auf dem gewählten Gerät wird geschlossen, hier läuft es an derselben Stelle weiter.")
        }
        .fullScreenCover(item: $abspielen, onDismiss: { Task { await laden() } }) { wunsch in
            PlayerScreen(model: model, item: wunsch.item,
                         plan: wunsch.plan, startAt: wunsch.startAt)
        }
        .task { if !stand.geladen { await laden() } }
        // **Beim Zurückkommen neu holen, mit Frist.**
        //
        // Hier lag der Fehler: die Seite lud genau einmal je App-Start, weil
        // `geladen` nie zurückgenommen wurde. Eine auf dem Fernseher zu Ende
        // gesehene Folge stand darum weiter mit Balken in der Reihe, während
        // der Player beim Antippen die Stelle frisch nachholte und richtig
        // bei null anfing. Die Kachel log, nicht der Player.
        //
        // Die Frist steht in `Auffrischung` und nicht hier: tvOS und macOS
        // zeigen dieselben Reihen und brauchen dieselbe Antwort.
        .onChange(of: lebenslage) { _, neu in
            guard neu == .active, stand.brauchtAuffrischung else { return }
            Task { await laden() }
        }
    }

    /// Wortmarke links, Profilbild rechts.
    ///
    /// Der Inhalt läuft beim Scrollen sichtbar darunter durch, statt an einer
    /// harten schwarzen Kante abzuschneiden. Die Lupe ist weg — Suchen ist
    /// jetzt ein eigener Bereich in der Leiste unten.
    @ViewBuilder private var kopf: some View {
        if breit {
            // **Kein Verlauf.** Er trägt auf dem iPhone die Kopfzeile, die
            // oben liegt — hier liegt die Leiste links, und über dem Inhalt
            // ist nichts, worunter er durchlaufen müsste. Ein Verlauf ohne
            // Kopfzeile ist Zierde, und die hat diese Gestaltung nicht.
            EmptyView()
        } else {
            kopfzeile
        }
    }

    private var kopfzeile: some View {
        Unschaerfekopf {
            HStack(alignment: .bottom) {
                Wortmarke(hoehe: 30)
                Spacer(minLength: 0)
                // **Links vom Profilbild, dicht daneben.** Dasselbe wie auf
                // dem Fernseher; nur ohne Text, weil oben auf dem Telefon
                // kein Platz für eine Zeile ist. Der Titel steht im Blatt,
                // das sich beim Antippen öffnet.
                if let angebot = uebernahme.angebot {
                    Button { abzeichenGedrueckt() } label: {
                        Image(systemName: angebot.geraetezeichen)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Stil.akzent)
                            .frame(width: 34, height: 34)
                            .background(Stil.akzent.opacity(0.14), in: Circle())
                            .overlay(Circle().strokeBorder(Stil.akzent.opacity(0.28)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Hier weiterschauen"))
                    .accessibilityValue(Text(angebot.titelzeile))
                    .padding(.trailing, 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
                NavigationLink(value: ProfilRoute()) {
                    Profilzeichen(name: model.session?.userName ?? "?",
                                  bild: model.benutzerbildURL())
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Stil.schrift)
            .animation(.easeInOut(duration: 0.22), value: uebernahme.angebot?.id)
        }
    }

    // MARK: - Auf diesem Gerät weiterschauen

    /// Bei einem Gerät sofort, bei mehreren erst fragen.
    private func abzeichenGedrueckt() {
        if uebernahme.mehrereDa { auswahlOffen = true }
        else if let eine = uebernahme.angebot { hierWeiterschauen(eine) }
    }

    /// Drüben beenden, hier an derselben Stelle weitermachen.
    ///
    /// Erst der Befehl, dann der Plan, dann der Start — geht das Beenden
    /// schief, passiert hier gar nichts. Sonst liefen zwei Tonspuren im Raum.
    private func hierWeiterschauen(_ sitzung: Fremdsitzung) {
        auswahlOffen = false
        Task {
            guard let (titel, ab) = await uebernahme.uebernehmen(sitzung, model: model)
            else { return }
            guard let plan = await model.plan(for: titel.id) else { return }
            abspielen = Abspielwunsch(item: titel, plan: plan, startAt: ab)
        }
    }

    /// Statt eines leeren schwarzen Bildschirms: sagen, was los ist, und einen
    /// Weg zurück anbieten.
    ///
    /// Der Text nennt die Serveradresse. Das ist der eigentliche Gewinn — daran
    /// erkennt man auf einen Blick, ob der Server aus ist oder man im falschen
    /// Netz steckt. Vorher stand da nur, dass etwas nicht ging.
    @ViewBuilder private var nichtsDa: some View {
        if stand.gestoert {
            Leerzustand(
                symbol: "externaldrive.badge.xmark",
                kopfzeile: "Kein Kontakt zum Server",
                text: "\(model.serverAdresse ?? String(localized: "Der Server")) hat nicht geantwortet. Läuft der Server, und bist du im selben Netz?",
                laedt: laedtNeu,
                hauptknopf: laedtNeu ? nil : ("Erneut versuchen", { neuVersuchen() }),
                stillerKnopf: laedtNeu ? nil : ("Server wechseln", { model.signOut() }))
        } else {
            Leerzustand(
                symbol: "tray",
                kopfzeile: "Hier ist noch nichts",
                text: "Sobald in Jellyfin etwas liegt, taucht es hier auf.",
                stillerKnopf: ("Aktualisieren", { neuVersuchen() }))
        }
    }

    private func neuVersuchen() {
        laedtNeu = true
        Task {
            await laden()
            laedtNeu = false
        }
    }

    private var inhalt: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Stil.reihenAbstand) {
                if !stand.weiterschauen.isEmpty {
                    Reihe(model: model, titel: "Weiterschauen",
                          items: stand.weiterschauen, quer: true, direkt: starte)
                }
                if !stand.naechsteFolge.isEmpty {
                    // Ohne 'direkt': eine noch nicht angefangene Folge will
                    // man erst ansehen, nicht sofort starten. Nur
                    // 'Weiterschauen' springt direkt in die Wiedergabe.
                    Reihe(model: model, titel: "Nächste Folge", items: stand.naechsteFolge)
                }
                if !stand.zuletzt.isEmpty {
                    // Hier führt der Tipp auf die Seite: was man noch nicht
                    // angefangen hat, will man erst ansehen.
                    Reihe(model: model, titel: "Zuletzt hinzugefügt",
                          items: stand.zuletzt, neuzugang: true)
                }
                // Die Reihe „Bibliotheken" ist entfallen — Filme und Serien
                // stehen jetzt in der Leiste unten.
            }
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        // Oben unter dem unscharfen Kopf durch, unten über der Leiste enden.
        //
        // Breit gibt es unten keine Leiste — die steht links. Der Platz, den
        // `leisteHoehe` freihält, wäre dort ein leerer Streifen.
        .contentMargins(.top, (breit ? Stil.kopfOben + 20 : 58)
                        + (fensterknoepfe ? Fensterknoepfe.hoehe : 0),
                        for: .scrollContent)
        .contentMargins(.bottom, breit ? 24 : Stil.leisteHoehe + 12,
                        for: .scrollContent)
        .refreshable { await laden() }
    }

    /// Aus den Fortsetzen-Reihen direkt in die Folge, ohne Zwischenseite.
    private func starte(_ item: Item) {
        guard !bereitet else { return }
        bereitet = true
        Task {
            defer { bereitet = false }
            // Frisch holen: die Position im Listeneintrag ist oft veraltet.
            let aktuell = await model.item(id: item.id) ?? item
            guard let plan = await model.plan(for: aktuell.id) else { return }
            abspielen = Abspielwunsch(item: aktuell, plan: plan,
                                      startAt: aktuell.fortsetzenAb ?? 0)
        }
    }

    private func laden() async { await stand.laden(model) }
}

/// Eine waagerecht scrollende Reihe.
private struct Reihe: View {
    @Environment(\.breit) private var breit
    let model: AppModel
    let titel: LocalizedStringKey
    let items: [Item]
    /// Waagerechte Kacheln statt hochkant — nur für „Weiterschauen".
    var quer = false
    /// Zeigt statt der Folgennummer, *was* neu dazugekommen ist.
    var neuzugang = false
    /// Gesetzt heißt: Tippen startet sofort, statt auf die Seite zu führen.
    var direkt: ((Item) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            // **Derselbe Rand wie die Kacheln darunter.** Der Baustein setzt
            // seit dem Herausloesen keinen eigenen mehr — auf tvOS gibt es
            // `randAbstand` nicht. Er muss hier `rand(breit:)` lesen, sonst
            // steht die Ueberschrift auf dem iPad schmaler als ihre Reihe.
            Reihentitel(text: titel)
                .padding(.horizontal, Stil.rand(breit: breit))

            ScrollView(.horizontal, showsIndicators: false) {
                // Oben ausrichten: ohne das zentriert der Stapel, und eine
                // Kachel mit nur einer Textzeile — ein Film ohne Folgenkürzel
                // — sitzt tiefer als die Serien daneben.
                HStack(alignment: .top, spacing: Stil.kachelAbstand) {
                    ForEach(items) { item in
                        if let direkt {
                            Button { direkt(item) } label: {
                                Kachel(model: model, item: item, quer: quer, neuzugang: neuzugang)
                            }
                            .buttonStyle(.plain)
                            // Zur Serie kommt man weiterhin — nur nicht mehr
                            // im Weg der Wiedergabe.
                            .contextMenu {
                                NavigationLink(value: item) {
                                    Label("Zur Übersicht", systemImage: "info.circle")
                                }
                            }
                        } else {
                            NavigationLink(value: item) {
                                Kachel(model: model, item: item, quer: quer, neuzugang: neuzugang)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
            }
        }
    }
}

private struct Kachel: View {
    @Environment(\.breit) private var breit
    let model: AppModel
    let item: Item
    var quer = false
    var neuzugang = false

    /// Waagerecht 16:9, so breit wie zwei Poster nebeneinander — sonst wirkt
    /// die Reihe leer.
    private var breite: CGFloat {
        quer ? Stil.reihenQuerBreite(breit: breit) : Stil.reihenBreite(breit: breit)
    }
    private var hoehe: CGFloat {
        quer ? Stil.reihenQuerHoehe(breit: breit) : Stil.reihenHoehe(breit: breit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Bild(url: quer ? model.querbildURL(for: item)
                           : model.imageURL(for: item, maxHeight: 500, hochkant: true),
                 breite: breite, hoehe: hoehe, ecke: Stil.eckeKachel,
                 fortschritt: fortschritt) {
                // Fehlt dem Titel ein waagerechtes Bild, tritt das Poster ein
                // — beschnitten, aber immer noch das Cover und kein Standbild.
                Bild(url: model.imageURL(for: item, maxHeight: 500, hochkant: true),
                     breite: breite, hoehe: hoehe, ecke: Stil.eckeKachel) {
                    // **Und wenn auch das fehlt, ein Zeichen statt Leere.**
                    //
                    // Eine leere Flaeche sieht aus wie ein Fehler in der App,
                    // und genau so wurde sie gemeldet. Ein Zeichen sagt: hier
                    // gehoert ein Bild hin, der Server hat keins.
                    Stil.flaeche.overlay {
                        Image(systemName: item.seriesId != nil ? "tv" : "film")
                            .font(.system(size: 22))
                            .foregroundStyle(Stil.schriftSehrLeise)
                    }
                }
            }
            #if DEBUG
            // Nur im Debug-Bau: in der ausgelieferten Fassung waere das eine
            // gebaute Adresse je Kachel, fuer nichts.
            .onAppear {
                guard quer, model.querbildURL(for: item) == nil else { return }
                Protokoll.schreib("[Bild] \(item.seriesName ?? item.name): kein Querbild — "
                    + "eigen=\(item.imageTags?.keys.sorted().joined(separator: ",") ?? "-") "
                    + "Serienposter=\(item.seriesPrimaryImageTag != nil) "
                    + "Serienhintergrund=\(item.parentBackdropImageTags?.count ?? 0) "
                    + "Serienvorschau=\(item.parentThumbImageTag != nil)")
            }
            #endif

            VStack(alignment: .leading, spacing: 1) {
                Text(item.seriesName ?? item.name)
                    .font(Stil.kachel)
                    .foregroundStyle(Stil.schrift)
                    .lineLimit(1)
                if let kuerzel = neuzugang ? item.neuzugangszeile : item.folgenkuerzel {
                    Text(kuerzel)
                        .font(Stil.klein)
                        .foregroundStyle(Stil.schriftLeise)
                }
            }
            .frame(width: breite, alignment: .leading)
        }
        // Eine Aussage je Kachel statt dreier Bruchstücke — und der
        // Fortschritt kommt mit. Er ist eine Zeichnung im Bild und fiel für
        // VoiceOver bisher ganz heraus; der tvOS-Chat hat es dort gefunden
        // und uns geprüft. Erst ab einem Prozent: „null Prozent gesehen" ist
        // keine Auskunft.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.trefferauskunft.isEmpty
                                 ? item.name
                                 : "\(item.seriesName ?? item.name), \(item.trefferauskunft)"))
        .accessibilityValue(fortschritt.map {
            Text("\(Int($0 * 100)) Prozent gesehen")
        } ?? Text(""))
    }

    private var fortschritt: Double? {
        guard let prozent = item.userData?.playedPercentage, prozent > 0 else { return nil }
        return prozent / 100
    }
}
