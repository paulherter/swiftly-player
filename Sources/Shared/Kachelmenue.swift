import JellyfinKit
import Observation
import SwiftUI

/// **Der Sehstand als Eintrag einer Handlungstafel** — derselbe Baustein
/// wie das Kachelmenü, für die Mehr-Tafel der Detailseite.
///
/// Film- und Serienseite führten „Gesehen" auf dem Mac und dem Fernseher als
/// eigenen Extra-Eintrag, zweimal abgeschrieben und schon verschieden
/// beschriftet („merken" hier, „markieren" dort und im Kachelmenü). Jetzt
/// steht er einmal hier, neben dem Menü, das dieselbe Frage an jeder Kachel
/// beantwortet, und trägt dessen Wortlaut. Audit PARITAET-1.0.5, Punkt 3.
///
/// **Ein Eintrag, der umschaltet**, nicht die zwei des Kachelmenüs: die
/// Seite kennt ihren Stand (`gesehen`) und schaltet sofort um — der Zustand
/// ist die Antwort (VERHALTEN D6). Sagt der Server nein, dreht er zurück und
/// meldet den Grund.
///
/// Dieser Teil der Datei gehört auch zum Mac-Ziel; das Menü selbst steht
/// dort in `Sources/macOS/KachelmenueMac.swift` (Rechtsklick statt langem
/// Druck) und ist deshalb unten ausgeklammert.
extension Titelhandlung {
    @MainActor
    static func sehstand(_ item: Item, model: AppModel,
                         gesehen: Binding<Bool>,
                         melden: @escaping (String) -> Void) -> Titelhandlung {
        Titelhandlung(symbol: gesehen.wrappedValue ? "checkmark.circle.fill" : "checkmark.circle",
                      text: gesehen.wrappedValue ? "Als ungesehen markieren" : "Als gesehen markieren") {
            gesehen.wrappedValue.toggle()
            Task {
                if let grund = await model.setzeGesehen(item, an: gesehen.wrappedValue) {
                    gesehen.wrappedValue.toggle()
                    melden(grund)
                }
            }
        }
    }
}

#if !os(macOS)
/// **Was ein Kachelmenü bei der App bestellt** — abspielen, das Ladeblatt,
/// eine Meldung.
///
/// Das Menü hängt an Kacheln auf Startseite, Bibliothek, Suche und Co.;
/// nicht jede dieser Seiten hat einen eigenen Player oder ein Ladeblatt.
/// Deshalb geht die Bitte an einen Halter für die ganze App, und `HauptView`
/// führt sie aus — wie bei ``Gemeinsammodell/wunsch``.
@MainActor
@Observable
final class Kachelwunsch {
    static let geteilt = Kachelwunsch()

    /// Was geladen werden soll, mit Titel und Bildern fürs Ladeblatt.
    struct Ladeauftrag {
        let posten: Downloadposten
        let titel: String
        let bilder: [String: URL]
    }

    var abspielen: Abspielwunsch?
    var laden: Ladeauftrag?
    var ladeblattOffen = false
    var meldung: String?
}

/// **Langer Druck auf eine Kachel — überall dasselbe Menü.**
///
/// Vorher hatte nur „Weiterschauen" eines (gesehen/ungesehen), die übrigen
/// Kacheln keins. Jetzt steht an jeder Film-, Serien- und Folgenkachel
/// dieselbe Liste, mit einer Vorschau (Bild, Titel, Jahr und Laufzeit):
/// Abspielen oder Fortsetzen, gesehen/ungesehen, Laden, Gemeinsam schauen,
/// und bei „Weiterschauen" das Herausnehmen aus der Reihe.
///
/// Die Handlungen selbst sind die, die es schon gibt: `Abspielwunsch.starten`,
/// `AppModel.setzeGesehen`, das `Ladeblatt`, `Gemeinsammodell.anlegenFuer`.
struct Kachelmenue: ViewModifier {
    let item: Item
    let model: AppModel
    /// Die Kachel steht in „Weiterschauen": dann gibt es „Zur Übersicht"
    /// (ein Tipp startet dort gleich) und „Aus Weiterschauen entfernen".
    var weiterschauen = false
    /// Nach einer Änderung am Sehstand, damit die Seite nachzieht.
    var nachher: (() async -> Void)?
    /// Die Kachel ist waagerecht (16:9, „Weiterschauen") statt hochkant.
    var quer = false
    /// **Im Player: nur der Sehstand.** Ohne „Abspielen" und „Gemeinsam
    /// schauen" — die Zeile selbst startet die Folge schon, und beides müsste
    /// den laufenden Player ersetzen. Ohne „Laden": das Ladeblatt ginge unter
    /// dem Player auf. Dieselbe Regel am Mac (`Sources/macOS/KachelmenueMac.swift`).
    var imPlayer = false

    /// Filme, Serien und Folgen — Sammlungen, Personen und Ordner haben
    /// nichts, was sich abspielen oder abhaken ließe.
    static func traegt(_ item: Item) -> Bool {
        ["Movie", "Series", "Episode"].contains(item.type ?? "")
    }

    func body(content: Content) -> some View {
        #if os(tvOS)
        // **Auf dem Fernseher ohne Vorschau**: die fokussierte Kachel steht
        // schon groß da, und tvOS hebt sie beim langen Druck selbst an.
        if Self.traegt(item) {
            content.contextMenu { eintraege }
                // Haelt die Kachel den Fokus, holt `KachelStil` den Stand
                // der Serie vor — siehe `Serienspeicher.naechsteVorladen`.
                .environment(\.kachelVorladen, { [item, model] in
                    await Serienspeicher.geteilt.naechsteVorladen(zu: item, mit: model)
                })
        } else {
            content
        }
        #else
        if Self.traegt(item) {
            content
                // Die Form, in der das System die Kachel hebt und zurücklegt —
                // dieselbe Ecke wie das Bild, damit Maske und Bild eins bleiben.
                .contentShape(.contextMenuPreview,
                              RoundedRectangle(cornerRadius: Stil.eckeKachel, style: .continuous))
                .contextMenu {
                eintraege
            } preview: {
                Kachelvorschau(item: item, model: model, quer: quer)
            }
        } else {
            content
        }
        #endif
    }

    private var istSerie: Bool { item.type == "Series" }

    @ViewBuilder
    private var eintraege: some View {
        if !imPlayer {
            Button { abspielen() } label: {
                if !istSerie, item.fortsetzenAb != nil {
                    Label("Fortsetzen", systemImage: "play.fill")
                } else {
                    Label("Abspielen", systemImage: "play.fill")
                }
            }
        }
        if weiterschauen {
            NavigationLink(value: item) {
                Label("Zur Übersicht", systemImage: "info.circle")
            }
        }
        // **Nur der Eintrag mit Wirkung** — außer bei Serien (teils gesehen)
        // und bei angefangenen Titeln: eine Folge, durch die man nur
        // gesprungen ist, gilt als angefangen; „ungesehen" holt sie aus
        // „Weiterschauen". Ein Eintrag ohne Wirkung wäre Rauschen, ein
        // fehlender Ausweg ein Fehler.
        let istGesehen = item.userData?.played ?? false
        let angefangen = item.fortsetzenAb != nil
        if istSerie || !istGesehen {
            Button { gesehen(true) } label: {
                Label("Als gesehen markieren", systemImage: "checkmark.circle")
            }
        }
        if istSerie || istGesehen || angefangen {
            Button { gesehen(false) } label: {
                Label("Als ungesehen markieren", systemImage: "eye.slash")
            }
        }
        // Der Fernseher lädt nichts herunter — es gibt dort keine Downloads.
        #if !os(tvOS)
        if !istSerie, !imPlayer, model.downloadKnopfZeigen, model.downloads.posten(fuer: item.id) == nil {
            Button { laden() } label: {
                Label("Laden", systemImage: "arrow.down.circle")
            }
        }
        #endif
        if !istSerie, !imPlayer, Gemeinsammodell.geteilt.darfAnlegen {
            Button { Gemeinsammodell.geteilt.anlegenFuer = item } label: {
                Label("Gemeinsam schauen", systemImage: "person.2")
            }
        }
        if weiterschauen {
            Button { entfernen() } label: {
                Label("Aus Weiterschauen entfernen", systemImage: "minus.circle")
            }
        }
    }

    // MARK: Handlungen

    /// Frisch holen: die Stelle im Listeneintrag ist oft veraltet. Bei einer
    /// Serie die Folge, bei der man steht.
    private func abspielen() {
        let model = model, item = item
        Task {
            var ziel = item
            if item.type == "Series" {
                // **Gestört ist nicht „nichts mehr".** Ohne Netz kam hier
                // dieselbe Auskunft wie bei einer Serie ohne Folgen.
                do {
                    guard let stand = try await model.standInSerieGeprueft(item) else {
                        Kachelwunsch.geteilt.meldung = String(localized: "Danach kommt nichts mehr.")
                        return
                    }
                    ziel = stand
                } catch {
                    Kachelwunsch.geteilt.meldung = lesbarerFehler(error)
                    return
                }
            }
            Abspielwunsch.starten(ziel, frisch: true, model: model, bereitet: .constant(false),
                                  fehlt: {
                                      // Statt Stille, wenn der Server keine Datei hat.
                                      Kachelwunsch.geteilt.meldung = String(localized: "Der Server hat keine Datei zu diesem Titel.")
                                  }) {
                Kachelwunsch.geteilt.abspielen = $0
            }
        }
    }

    private func gesehen(_ an: Bool) {
        let model = model, item = item, nachher = nachher
        Task {
            if let fehler = await model.setzeGesehen(item, an: an) {
                Kachelwunsch.geteilt.meldung = fehler
                return
            }
            await nachher?()
        }
    }

    private func entfernen() {
        let model = model, item = item, nachher = nachher
        Task {
            if let fehler = await model.ausWeiterschauenNehmen(item) {
                Kachelwunsch.geteilt.meldung = fehler
                return
            }
            await nachher?()
        }
    }

    /// Frisch geholt, weil Reihen und Suche ihre Titel ohne Dateiangaben
    /// liefern — das Ladeblatt braucht Größe und Container.
    private func laden() {
        let model = model, item = item
        Task {
            guard let konto = model.session?.userID else { return }
            let titel = await model.item(id: item.id) ?? item
            let quelle = titel.mediaSources?.first
            let folge = titel.type == "Episode"
            let posten = Downloadposten(
                id: titel.id, konto: konto, art: folge ? .folge : .film, titel: titel.name,
                serie: folge ? titel.seriesName : nil, serienId: folge ? titel.seriesId : nil,
                staffel: folge ? titel.parentIndexNumber : nil,
                folge: folge ? titel.indexNumber : nil,
                laufzeitTicks: titel.runTimeTicks, container: quelle?.container,
                quelle: quelle?.id, bytes: quelle?.size ?? 0,
                sehstand: titel.userData, bildcodec: quelle?.bildcodec)
            var bilder: [String: URL] = [:]
            if folge {
                if let sid = titel.seriesId,
                   let plakat = model.imageURL(for: titel, maxHeight: 600, hochkant: true) {
                    bilder[sid] = plakat
                }
                if let quer = model.querbildURL(for: titel) { bilder[titel.id] = quer }
            } else if let plakat = model.plakatURL(itemID: titel.id,
                                                   marke: titel.imageTags?["Primary"]) {
                bilder[titel.id] = plakat
            }
            Kachelwunsch.geteilt.laden = .init(posten: posten, titel: titel.name, bilder: bilder)
            Kachelwunsch.geteilt.ladeblattOffen = true
        }
    }
}

#if !os(tvOS)
/// **Die Vorschau über dem Menü** — Querbild, darunter Titel und die
/// Angaben, die man vor dem Tippen wissen will: Jahr und Laufzeit, bei einer
/// Folge Staffel, Folge und ihr Name.
private struct Kachelvorschau: View {
    let item: Item
    let model: AppModel
    let quer: Bool

    /// **Dasselbe Bild wie die Kachel, im selben Seitenverhältnis**
    /// (27.09.2026, Pauls Rückmeldung). Vorher: ein größeres Querbild in 16:9
    /// — es war nicht im Speicher, das Menü ging leer auf, und beim
    /// Zurückfedern skalierte das System ein 16:9-Bild in eine 2:3-Kachel:
    /// links und rechts sah man für einen Moment einen Rand. Jetzt dieselbe
    /// Adresse (der Speicher antwortet sofort, `Bildspeicher`) und dieselbe
    /// Form, nur größer.
    private var adresse: URL? {
        let plakat = model.imageURL(for: item, maxHeight: 500, hochkant: true)
        return quer ? (model.querbildURL(for: item) ?? plakat) : plakat
    }
    private var breite: CGFloat { quer ? 320 : 220 }
    private var hoehe: CGFloat { quer ? breite * 9 / 16 : breite * 3 / 2 }

    private var zeile: String {
        if item.type == "Episode" {
            var teile: [String] = []
            if let kuerzel = item.folgenkuerzel { teile.append(kuerzel) }
            teile.append(item.name)
            if let s = item.runtimeSeconds, s > 0 { teile.append(laufzeit(s)) }
            return teile.joined(separator: " · ")
        }
        return item.nebenzeile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Bild(url: adresse, breite: breite, hoehe: hoehe, ecke: 0)
                .frame(width: breite, height: hoehe)
                .clipped()
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.seriesName ?? item.name)
                    .font(Stil.listentitel)
                    .foregroundStyle(Stil.schrift)
                    .lineLimit(1)
                if !zeile.isEmpty {
                    Text(verbatim: zeile)
                        .font(Stil.klein)
                        .monospacedDigit()
                        .foregroundStyle(Stil.schriftLeise)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: breite, alignment: .leading)
        }
        .background(Stil.grund)
        #if DEBUG
        .onAppear {
            Protokoll.schreib("[Kachelmenü] Vorschau \(Int(breite))×\(Int(hoehe)) · "
                + (quer ? "16:9" : "2:3") + " · Bild im Speicher: "
                + (adresse.flatMap { Bildspeicher.geteilt.bild($0) } != nil ? "ja" : "nein"))
        }
        #endif
    }
}

#endif

extension View {
    /// Das Kachelmenü — siehe ``Kachelmenue``.
    func kachelmenue(_ item: Item, model: AppModel, weiterschauen: Bool = false,
                     quer: Bool = false, imPlayer: Bool = false,
                     nachher: (() async -> Void)? = nil) -> some View {
        modifier(Kachelmenue(item: item, model: model, weiterschauen: weiterschauen,
                             nachher: nachher, quer: quer, imPlayer: imPlayer))
    }
}
#endif
