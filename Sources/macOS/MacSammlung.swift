import JellyfinKit
import SwiftUI

// MARK: - Sammlungsseite

/// **Eine Sammlung als Unterseite** — Vorlage ist `SammlungView` in
/// `Sources/Shared/Sammlungsseite.swift`.
///
/// Die Sammlungsseite ist eine Bibliotheksseite: Pfeil, Name, Filter und
/// Sortierung, Raster. Sie ist deshalb `BibliothekView` mit einer Sammlung
/// als Quelle, keine eigene Bauart. Sortiert ist voreingestellt nach Jahr,
/// und zwar aufsteigend (``Regalquelle/richtung(_:)``), damit eine Reihe in
/// ihrer Folge steht.
///
/// Sortierung und Filter werden **nicht** gemerkt: eine Sammlung ist kein
/// Ort, an den man zurückkehrt, sondern ein Blick in eine Reihe. Das Regal
/// gehört deshalb der Seite und hat keinen Merknamen.
struct Sammlungsseite: View {
    let model: AppModel
    let sammlung: Item
    /// Ob ihre Filme oder ihre Serien gemeint sind — `nil`: alles, was in ihr
    /// steht (aus Suche oder Merkliste, ohne Bereich).
    let art: String?
    let zurueck: () -> Void

    @State private var regal: Bibliotheksmodell

    init(model: AppModel, sammlung: Item, art: String?, zurueck: @escaping () -> Void) {
        self.model = model
        self.sammlung = sammlung
        self.art = art
        self.zurueck = zurueck
        let regal = Bibliotheksmodell()
        regal.sortierung = .erscheinung
        _regal = State(initialValue: regal)
    }

    var body: some View {
        BibliothekView(model: model,
                       art: art ?? "movies",
                       titel: LocalizedStringKey(sammlung.name),
                       regal: regal,
                       wahl: .constant(.alle),
                       sammlung: (sammlung, art),
                       // Bei Serien derselbe Satz wie auf dem iPhone.
                       filter: art == "tvshows" ? [.alle, .angefangen, .merkliste]
                                                : Bibliotheksfilter.allCases,
                       zurueck: zurueck)
    }
}

// MARK: - Ersatzplakat

/// **Ersatzplakat einer Sammlung ohne eigenes Bild** — ein Mosaik aus den
/// Plakaten ihrer ersten Titel, im Format und mit den Ecken jeder
/// `Posterkachel`. Vorlage und Begründung: `Sammlungsmosaik` in
/// `Sources/Shared/Sammlungsseite.swift`.
///
/// Ein einzelner Titel füllt das ganze Feld, zwei stehen nebeneinander, ab
/// drei wird daraus ein 2×2-Mosaik. Die Plakate kommen klein (260 Punkt
/// Höhe): eine Mosaikkachel braucht kein Bild in Kachelgröße.
struct Sammlungsmosaik: View {
    let model: AppModel
    let sammlung: Sammlung
    let art: String
    var breite: CGFloat = Stil.kachelBreite
    var hoehe: CGFloat = Stil.kachelHoehe

    @State private var titel: [Item] = []

    private var reihen: [[Item]] {
        titel.isEmpty ? [] : (titel.count > 2 ? [Array(titel.prefix(2)), Array(titel[2...].prefix(2))]
                                               : [titel])
    }

    var body: some View {
        let platz = reihen.isEmpty ? [[]] : reihen
        let reihenHoehe = (hoehe - CGFloat(platz.count - 1) * 2) / CGFloat(platz.count)
        VStack(spacing: 2) {
            ForEach(Array(platz.enumerated()), id: \.offset) { _, stapel in
                zeile(stapel, hoehe: reihenHoehe)
            }
        }
        .frame(width: breite, height: hoehe)
        .clipShape(RoundedRectangle(cornerRadius: Stil.eckeKachel, style: .continuous))
        .task(id: sammlung.id) {
            let gefunden = await model.sammlungstitel(sammlung, art: art)
            withAnimation(Stil.einblenden) { titel = Array((gefunden ?? []).prefix(4)) }
        }
    }

    private func zeile(_ stapel: [Item], hoehe: CGFloat) -> some View {
        let feldbreite = stapel.isEmpty ? breite : (breite - CGFloat(stapel.count - 1) * 2) / CGFloat(stapel.count)
        return HStack(spacing: 2) {
            if stapel.isEmpty {
                feld(url: nil, breite: feldbreite, hoehe: hoehe)
            } else {
                ForEach(stapel) { eintrag in
                    feld(url: model.imageURL(for: eintrag, maxHeight: 260, hochkant: true),
                         breite: feldbreite, hoehe: hoehe)
                }
            }
        }
    }

    private func feld(url: URL?, breite: CGFloat, hoehe: CGFloat) -> some View {
        ZStack {
            Stil.flaeche
            Netzbild(url: url, zeichen: "film", anzeigekante: max(breite, hoehe))
        }
        .frame(width: breite, height: hoehe)
        .clipped()
    }
}

// MARK: - Detailseite: Teil der Sammlung

/// **Die Reihe „Teil der Sammlung" auf der Filmseite** — die anderen Titel
/// der Sammlung, in ihrer Folge. Ihr Kopf öffnet die Sammlungsseite.
/// Vorlage: `Sammlungsreihe` in `Sources/Shared/Sammlungsseite.swift`.
///
/// Die Mitgliedschaft steht im ``Sammlungsverzeichnis``, das einmal je Konto
/// geladen wird; nur die Plakate der Reihe kommen frisch vom Server. Fehlt
/// die Sammlung, fehlt die Reihe — wie bei den Extras.
///
/// **Die Reihen lädt die Filmseite, nicht die Reihe selbst.** Dort stehen
/// alle Reihen in einem Stapel mit festem Abstand; eine leere Ansicht, die
/// nur zum Laden dastünde, bekäme diesen Abstand mit, und unter den Extras
/// klaffte eine Lücke. `ForEach` über nichts steht dagegen gar nicht da.
struct Sammlungsreihe: View {
    typealias Reihe = (sammlung: Sammlung, titel: [Item])

    let model: AppModel
    let reihe: Reihe

    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich
    @State private var schwebt = false

    /// Ob ihre Filme oder ihre Serien gemeint sind.
    let art: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                navigator.oeffne(.sammlung(reihe.sammlung.item, art: art), in: bereich)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Reihentitel(text: "Teil der Sammlung")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(schwebt ? Stil.schrift : Stil.schriftSehrLeise)
                    }
                    Text(verbatim: reihe.sammlung.item.name)
                        .font(Stil.koerper)
                        .foregroundStyle(Stil.schriftLeise)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(Stil.Druckknopf())
            .onHover { schwebt = $0 }
            .animation(Stil.zeitSchweben, value: schwebt)

            Blätterreihe(rand: 0) {
                ForEach(reihe.titel, id: \.id) { eintrag in
                    Button { navigator.oeffne(.titel(eintrag), in: bereich) } label: {
                        Posterkachel(titel: eintrag.name,
                                     zweitzeile: eintrag.productionYear.map { "\($0)" },
                                     bild: model.imageURL(for: eintrag, hochkant: true),
                                     fortschritt: eintrag.userData?.playedPercentage.map { $0 / 100 },
                                     marke: Anzeigeregeln.kachelmarke(
                                        art: eintrag.type,
                                        staffeln: eintrag.childCount,
                                        gesehen: eintrag.userData?.played,
                                        offeneFolgen: eintrag.userData?.unplayedItemCount),
                                     zeichen: eintrag.type == "Series" ? "tv" : "film")
                    }
                    .buttonStyle(Stil.Druckknopf())
                }
            }
        }
    }

    /// Die Reihen zu einem Titel — höchstens zwei. Steht ein Film in mehr
    /// Sammlungen, sind die übrigen meist automatisch angelegte Doppel.
    static func laden(_ model: AppModel, titel: Item) async -> [Reihe] {
        guard let art = Bibliotheksgattung.art(zuTyp: titel.type) else { return [] }
        await model.angebotLaden()
        var gefunden: [Reihe] = []
        for sammlung in model.sammlungen(mit: titel).prefix(2) {
            guard let liste = await model.sammlungstitel(sammlung, art: art) else { continue }
            let andere = Listenregeln.ohneDoppelte(liste).filter { $0.id != titel.id }
            if !andere.isEmpty { gefunden.append((sammlung, andere)) }
        }
        return gefunden
    }
}
