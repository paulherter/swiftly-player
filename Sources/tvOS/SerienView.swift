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

                handlungen

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

    /// **Der Kopf traegt hier nur Text.**
    ///
    /// Kein Abspielknopf: die Folge, bei der es weitergeht, steht in der
    /// Reihe darunter und hat beim Oeffnen den Fokus. „Fortsetzen · S2 F4"
    /// waere ein zweiter Weg zu derselben Sache, einen Druck weiter weg.
    ///
    /// „Von vorn" faellt damit auch weg — es hing an dem Knopf und meinte
    /// dieselbe Folge. Es steht weiter in der Handlungstafel („Folge von vorn
    /// abspielen"), also ist nichts verloren.
    ///
    /// Merkliste, Gesehen und Mehr stehen unter den Folgen. Ein Film wird
    /// abgespielt, eine Serie wird durchgesehen — was man an ihr **tut**,
    /// gehoert hinter das, worum es geht.
    private var kopf: some View {
        Detailkopf(model: model, item: aktuell, plan: plan,
                   fokussierbar: false) { EmptyView() }
    }

    /// Merkliste, Gesehen und Mehr — unter den Folgen.
    private var handlungen: some View {
        HStack(spacing: 24) {
            Zustandsknoepfe(model: model, item: aktuell,
                            gemerkt: $gemerkt, gesehen: $gesehen,
                            meldung: $meldung)

            Mehrknopf(offen: $mehrOffen)
                // **Die Tafel haengt am Knopf und klappt nach oben.**
                //
                // Der feste Platz (`unterDerKnopfreihe`) galt fuer eine
                // Knopfreihe im Kopf. Hier steht sie bei rund 996 — darunter
                // ist kein Platz mehr, und die Seite scrollt ausserdem. Am
                // Knopf haengend wandert sie mit.
                .overlay(alignment: .bottomLeading) {
                    if mehrOffen {
                        Handlungstafel(handlungen: mehrHandlungen, offen: $mehrOffen)
                            .padding(.bottom, Stil.knopfHoehe + 14)
                            .transition(.opacity)
                    }
                }
                .zIndex(1)
        }
        .padding(.horizontal, Stil.randSeite)
        // Oben liegen schon 48 aus dem Folgenabschnitt, unten kommen die 24
        // des naechsten Reihenkopfs dazu — mit diesen 24 steht der Block
        // gleich weit von beidem entfernt.
        .padding(.bottom, Stil.reihenKopfLuft)
        .focusSection()
    }

    // MARK: Folgen

    @ViewBuilder
    private var folgenstreifen: some View {
        if laedtFolgen {
            // Der Lader steht so hoch wie der Streifen, den er ersetzt —
            // sonst springt die halbe Seite, sobald die Folgen ankommen.
            Lader()
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
        Titelhandlungen.fuerSerie(aktuell, stand: weiterMit, staffel: gewaehlteStaffel,
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

    private func starte(_ folge: Item?) {
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
                                      startAt: ziel.fortsetzenAb ?? 0)
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
