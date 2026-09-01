import JellyfinKit
import SwiftUI

/// Die Serienseite: oben derselbe Kopf wie bei einem Film, darunter die
/// Folgen, die Besetzung und Ähnliches.
///
/// **Keine Reiter mehr.** Vorher standen „Folgen", „Besetzung" und
/// „Ähnliches" als drei Schalter nebeneinander, und nur einer war jeweils zu
/// sehen. Der Entwurf legt sie stattdessen untereinander — dieselbe Bauart
/// wie die Startseite, jede Reihe ein `Section`-Abschnitt. Damit entfällt
/// auch der Umweg, den die Reiter nötig gemacht hatten: ein eigener
/// `onMoveCommand`, der den Fokus von Hand nach oben schob, weil links über
/// „Folgen" nichts Fokussierbares stand.
///
/// Die Folgen sind jetzt ein waagerechter Streifen mit denselben Querkacheln
/// wie „Weiterschauen", nicht mehr eine senkrechte Liste. `Folgenzeile`
/// bleibt trotzdem — das Folgenblatt im Player benutzt sie weiter.
struct SerienView: View {
    let model: AppModel
    let serie: Item
    /// Kommt man über eine einzelne Folge, ist deren Staffel schon gewählt.
    var startStaffelID: String?

    @State private var frisch: Item?
    @State private var plan: PlaybackPlan?
    @State private var staffeln: [Item] = []
    @State private var gewaehlteStaffel: Item?
    @State private var folgen: [Item] = []
    @State private var laedtFolgen = true
    @State private var gemerkt = false
    @State private var gesehen = false
    @State private var meldung: String?
    /// Der Player liegt im Rahmen — siehe `HauptView`.
    @Environment(\.abspielwunsch) private var abspielen
    @State private var bereitet = false
    @State private var weiterMit: Item?
    @State private var aehnliche: [Item] = []
    @State private var mehrOffen = false
    @State private var staffelwahlOffen = false
    /// Welche Folgenkachel den Fokus hat.
    @FocusState private var amFolge: String?
    /// Damit der Startfokus einmal gesetzt wird und nicht bei jedem Laden.
    @State private var startfokusGesetzt = false

    private var aktuell: Item { frisch ?? serie }
    private var darsteller: [Person] { (aktuell.people ?? []).filter(\.istDarsteller) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                kopf

                reihenabschnitt {
                    HStack(spacing: 34) {
                        Reihentitel(text: "Folgen")
                        if staffeln.count > 1, let staffel = gewaehlteStaffel {
                            Staffelpille(name: staffel.name, offen: $staffelwahlOffen)
                        }
                    }
                } inhalt: {
                    folgenstreifen
                }

                if !darsteller.isEmpty {
                    reihenabschnitt {
                        Reihentitel(text: "Besetzung")
                    } inhalt: {
                        Besetzungsstreifen(model: model, leute: darsteller)
                    }
                }
                if !aehnliche.isEmpty {
                    reihenabschnitt {
                        Reihentitel(text: "Ähnliches")
                    } inhalt: {
                        Titelstreifen(model: model, items: aehnliche)
                    }
                }
            }
            .padding(.bottom, Stil.abschlussLuft)
        }
        .scrollIndicators(.hidden)
        // Rand wie auf der Filmseite — siehe dort.
        .ignoresSafeArea()
        // Die Staffelwahl liegt auf der **Seite**, nicht am Pillenknopf —
        // siehe `Handlungstafel.unterDemReihenkopf`.
        .overlay(alignment: .topLeading) {
            if staffelwahlOffen {
                Handlungstafel(handlungen: staffelhandlungen, offen: $staffelwahlOffen)
                    .padding(.leading, Stil.randSeite)
                    .padding(.top, Handlungstafel.unterDemReihenkopf)
                    .transition(.opacity)
            }
        }
        // Das Mehr-Blatt an derselben Stelle wie auf der Filmseite. Es hing
        // vorher am Knopf und klappte nach oben auf, weil die Knopfreihe
        // unter den Folgen stand; jetzt steht sie wieder im Kopf, also gilt
        // wieder der feste Platz (VERHALTEN.md D7).
        .overlay(alignment: .topLeading) {
            if mehrOffen {
                Handlungstafel(handlungen: mehrHandlungen, offen: $mehrOffen)
                    .padding(.leading, Stil.randSeite)
                    .padding(.top, Handlungstafel.unterDerKnopfreihe)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: mehrOffen)
        .animation(.easeInOut(duration: 0.18), value: staffelwahlOffen)
        .overlay(alignment: .top) {
            if let meldung {
                Hinweisstreifen(text: meldung) { self.meldung = nil }
                    .padding(.top, Stil.randOben)
            }
        }
        // **Beim Oeffnen steht der Fokus auf der laufenden Folge.**
        //
        // Der Streifen ist ohnehin dorthin gescrollt; ohne Zuweisung faende
        // tvOS die vorderste Kachel meist von selbst. „Meist" ist auf dieser
        // Seite aber zu wenig — der Kopf hat seit dem Umbau nichts
        // Fokussierbares mehr, und wo der Fokus dann landet, entscheidet
        // sonst die Geometrie.
        //
        // `initial: true` laeuft beim Erscheinen mit und noch einmal, sobald
        // die Folgen geladen sind. Einmal gesetzt heisst einmal — sonst
        // risse jedes Auffrischen den Fokus zurueck.
        .onChange(of: folgeVorn, initial: true) { _, id in
            guard !startfokusGesetzt, let id else { return }
            startfokusGesetzt = true
            amFolge = id
        }
        .task { await laden() }
        .task(id: gewaehlteStaffel?.id) { await folgenLaden() }
    }

    // MARK: Kopf

    /// **Kopf wie auf der Filmseite: Text und Knopfreihe.**
    ///
    /// Eine Zwischenfassung hatte den Abspielknopf hier entfernt, mit dem
    /// Argument, die Folge stehe ja fokussiert in der Reihe darunter. Das
    /// stand gegen die freigegebene Tafel (`Serie-Neu.dc.html`), in der
    /// „Fortsetzen · S2 F4", „Von vorn", „Merkliste" und „Gesehen" im Kopf
    /// stehen, und gegen A9 und E6 im Verhaltensregister: dieselbe Reihenfolge
    /// auf jeder Plattform, ein Hauptknopf je Seite.
    ///
    /// **Weiss wird er nicht durch einen eigenen Stil, sondern durch den
    /// Fokus.** `KnopfStil` faerbt die fokussierte Pille weiss, und der Fokus
    /// faellt beim Oeffnen auf den ersten Knopf der Reihe. So loest tvOS E6 —
    /// dieselbe Regel wie ueberall hier: Fokus ist weiss.
    private var kopf: some View {
        Detailkopf(model: model, item: aktuell, plan: plan) {
            HStack(spacing: 24) {
                Button { starte(weiterMit) } label: {
                    Label(hauptknopftext, systemImage: "play.fill")
                }
                .buttonStyle(KnopfStil())
                .disabled(bereitet || weiterMit == nil)

                // Nur, wenn ueberhaupt etwas fortzusetzen ist — sonst meinte
                // „Von vorn" dasselbe wie der Knopf daneben.
                if angefangen {
                    Button { starte(weiterMit, ab: 0) } label: {
                        Label("Von vorn", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(KnopfStil())
                    .disabled(bereitet)
                }

                Zustandsknoepfe(model: model, item: aktuell,
                                gemerkt: $gemerkt, gesehen: $gesehen,
                                meldung: $meldung)

                Mehrknopf(offen: $mehrOffen)
            }
        }
    }

    /// Ob die Folge, bei der es weitergeht, schon angefangen ist.
    private var angefangen: Bool {
        (weiterMit?.userData?.playbackPositionTicks ?? 0) > 0
    }

    /// „Fortsetzen S1 • E3" — **nachgelesen bei iOS**, nicht erfunden.
    ///
    /// Wortlaut und Faelle stammen aus `Sources/Shared/SeriesView.swift`:
    /// angefangen heisst „Fortsetzen", sonst „Abspielen", dazu das Kuerzel
    /// aus `Item.folgenkuerzel`. Die beiden Wartefaelle ebenso.
    ///
    /// Dass das jetzt zweimal dasteht, ist gemeldet: die Beschriftung
    /// gehoert in den Zustandshalter, und der Weg dorthin fuehrt ueber iOS.
    private var hauptknopftext: String {
        guard let stand = weiterMit else {
            return laedtFolgen ? String(localized: "Lädt…")
                               : String(localized: "Keine Folgen")
        }
        let kuerzel = stand.folgenkuerzel ?? stand.name
        return angefangen ? String(localized: "Fortsetzen \(kuerzel)")
                          : String(localized: "Abspielen \(kuerzel)")
    }

    // MARK: Folgen

    @ViewBuilder
    private var folgenstreifen: some View {
        if laedtFolgen {
            // Der Lader steht so hoch wie der Streifen, den er ersetzt —
            // sonst springt die halbe Seite, sobald die Folgen ankommen.
            Lader.fern
                .frame(maxWidth: .infinity)
                .frame(height: Stil.querHoehe + 2 * Stil.reihenLuft + 80)
        } else if folgen.isEmpty {
            Leerzustand(symbol: "rectangle.stack",
                        titel: "Keine Folgen in dieser Staffel")
                .frame(height: Stil.querHoehe + 2 * Stil.reihenLuft + 80)
        } else {
            Folgenstreifen(model: model, folgen: folgen,
                           weiterMit: folgeVorn, amFolge: $amFolge) { folge in
                starte(folge)
            }
            // **Je Staffel ein eigener Streifen.** Der Anfangsstand steckt
            // in seinem Zustand, und Zustand ueberlebt einen Wechsel der
            // Eintraege. Ohne eigene Kennung stuende nach dem Staffelwechsel
            // die Folge einer anderen Staffel vorn — beziehungsweise deren
            // Platz, denn die Kachel gibt es dort nicht mehr.
            .id(gewaehlteStaffel?.id)
        }
    }

    /// Welche Folge vorn stehen soll.
    ///
    /// Nur, wenn `weiterMit` **in der gezeigten Staffel** liegt. Sonst waere
    /// es die falsche Reihe: nach einem Staffelwechsel will man F1 sehen,
    /// nicht eine Folge aus einer anderen Staffel, die hier gar nicht steht.
    private var folgeVorn: String? {
        guard let stand = weiterMit,
              stand.seasonId == gewaehlteStaffel?.id,
              folgen.contains(where: { $0.id == stand.id })
        else { return nil }
        return stand.id
    }

    /// Die Staffeln als Handlungstafel — kein `Menu`, wie überall in der App.
    private var staffelhandlungen: [Titelhandlung] {
        staffeln.map { staffel in
            Titelhandlung(symbol: gewaehlteStaffel?.id == staffel.id
                                  ? "checkmark.circle.fill" : "circle",
                          text: "\(staffel.name)") {
                gewaehlteStaffel = staffel
            }
        }
    }

    // MARK: Beschriftung und Laden

    private func laden() async {
        async let frischeSerie = model.item(id: serie.id)
        async let liste = model.staffeln(serie)
        async let stand = model.standInSerie(serie)

        frisch = await frischeSerie
        staffeln = await liste
        weiterMit = await stand
        gemerkt = aktuell.userData?.isFavorite ?? false
        gesehen = aktuell.userData?.played ?? false

        if gewaehlteStaffel == nil {
            // Über eine Folge gekommen: deren Staffel steht vorn. Sonst die,
            // in der es weitergeht — und erst dann die erste.
            let gesucht = startStaffelID ?? weiterMit?.seasonId
            gewaehlteStaffel = staffeln.first { $0.id == gesucht } ?? staffeln.first
        }
        if let ziel = weiterMit {
            plan = await model.plan(for: ziel.id)
        }
        aehnliche = await model.aehnliche(serie)
    }

    private func folgenLaden() async {
        guard let staffel = gewaehlteStaffel else { return }
        laedtFolgen = true
        folgen = await model.folgen(serie: serie.id, staffel: staffel.id)
        laedtFolgen = false
    }

    private var mehrHandlungen: [Titelhandlung] {
        // Gesehen steht vorn, wie auf der Filmseite — aus der Knopfreihe
        // heraus und eine Ebene tiefer. Siehe `gesehenHandlung`.
        [gesehenHandlung(model: model, item: aktuell,
                         gesehen: $gesehen, meldung: $meldung)]
        + Titelhandlungen.fuerSerie(aktuell, stand: weiterMit, staffel: gewaehlteStaffel,
                                  model: model,
                                  folgeStarten: { folgeStarten($0, ab: $1) },
                                  melden: { meldung = $0 },
                                  auffrischen: { await auffrischen() })
    }

    private func folgeStarten(_ folge: Item, ab: Double) {
        Task {
            guard let plan = await model.plan(for: folge.id) else {
                meldung = String(localized: "Die Folge konnte nicht geladen werden.")
                return
            }
            abspielen.wrappedValue = Abspielwunsch(item: folge, plan: plan, startAt: ab)
        }
    }

    /// **Alles neu, nicht nur die Serie.**
    ///
    /// Erster Anlauf holte Titel und Folgen, aber nicht `weiterMit`. Nach
    /// „Staffel als gesehen" haette der Hauptknopf weiter „Folge 3
    /// fortsetzen" angeboten, obwohl der Server sie als gesehen fuehrt — und
    /// der Beleg haette den Plan der alten Folge gezeigt.
    ///
    /// Deshalb ueber `laden()`: was beim Oeffnen geholt wird, muss auch beim
    /// Auffrischen geholt werden, sonst laufen die beiden Wege auseinander.
    /// Die gewaehlte Staffel bleibt dabei stehen.
    private func auffrischen() async {
        await laden()
        await folgenLaden()
    }

    /// `ab` uebersteuert die gemerkte Stelle — das ist „Von vorn".
    ///
    /// Ohne Angabe gilt A5: eine Folge startet an **ihrer eigenen** Stelle.
    private func starte(_ folge: Item?, ab: Double? = nil) {
        guard let folge, !bereitet else { return }
        bereitet = true
        Task {
            defer { bereitet = false }
            let ziel = await model.item(id: folge.id) ?? folge
            guard let plan = await model.plan(for: ziel.id) else {
                meldung = String(localized: "Der Server nennt keine Quelle für diese Folge.")
                return
            }
            abspielen.wrappedValue = Abspielwunsch(item: ziel, plan: plan,
                                      startAt: ab ?? ziel.fortsetzenAb ?? 0)
        }
    }
}

// MARK: - Eine Folge in der Liste

/// Vorschaubild links, Titel, Laufzeit und zwei Zeilen Beschreibung rechts —
/// derselbe Aufbau wie auf dem iPhone, nur in Fernsehmaßen.
///
/// Steht seit dem neuen Entwurf **nur noch im Folgenblatt** des Players: dort
/// liegt die Liste über dem laufenden Bild, und eine senkrechte Liste ist
/// dafür richtig. Auf der Serienseite sind die Folgen jetzt ein waagerechter
/// Streifen — siehe `Folgenstreifen`.
struct Folgenzeile: View {
    let model: AppModel
    let folge: Item
    let aktion: () -> Void

    var body: some View {
        Button(action: aktion) {
            HStack(alignment: .top, spacing: 34) {
                // `querbildURL` baut die Adresse aus `seriesId ?? id` — bei
                // einer Folge ist `seriesId` gesetzt, also kam für jede Folge
                // derselbe Serienhintergrund heraus. `imageURL` ohne
                // `hochkant` löst dagegen über `imageTags["Primary"]` das
                // eigene Vorschaubild der Folge auf; genau so macht es die
                // iPhone-Fassung. Nur wenn eine Folge keines hat, tritt der
                // Serienhintergrund als Rückfall ein.
                Bild(url: model.imageURL(for: folge, maxHeight: 360)
                          ?? model.querbildURL(for: folge, breite: 640),
                     breite: 320, hoehe: 180, ecke: Stil.ecke,
                     fortschritt: fortschritt)

                VStack(alignment: .leading, spacing: 0) {
                    Text(kopfzeile)
                        .font(.system(size: 31, weight: .semibold))
                        .lineLimit(1)

                    if let sekunden = folge.runtimeSeconds {
                        Text("\(Int(sekunden / 60)) Min")
                            .font(Stil.klein)
                            .foregroundStyle(Stil.schriftSehrLeise)
                            .padding(.top, 4)
                    }

                    if let text = folge.overview, !text.isEmpty {
                        Text(text)
                            .font(Stil.kachel)
                            .lineSpacing(9)
                            .foregroundStyle(Stil.schriftLeise)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .padding(.top, 12)
                    }
                }
                .padding(.top, 6)

                Spacer(minLength: 0)

                // Gesehene Folgen tragen einen leisen Haken am rechten Rand
                // — genau wie auf dem iPhone. Ohne den sieht man der Liste
                // nicht an, wo man stehengeblieben ist.
                if folge.istGesehen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Stil.schriftSehrLeise)
                        .padding(.top, 12)
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 26)
        }
        .buttonStyle(FolgenStil())
    }

    private var kopfzeile: String {
        if let nummer = folge.indexNumber { return "F\(nummer) · \(folge.name)" }
        return folge.name
    }

    private var fortschritt: Double? { folge.gesehenerAnteil }
}

/// Fokus auf einer Folgenzeile: eine ruhige Fläche.
///
/// Anders als bei Kacheln, wo nur die Größe spricht — eine Zeile ist kein
/// Bild, sie kann nicht heller werden. Dieselbe Fläche wie ein ruhender Chip.
struct FolgenStil: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration)
    }

    private struct Inhalt: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var fokus

        var body: some View {
            configuration.label
                .foregroundStyle(Stil.schrift)
                .background(fokus ? Color.white.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: Stil.eckeKachel))
                .animation(Stil.fokusAnimation, value: fokus)
        }
    }
}
