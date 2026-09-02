import AppKit
import JellyfinKit
import SwiftUI

/// Die Detailseite. Film und Serie tragen **denselben Kopf** — das ist auf dem
/// iPhone so entschieden und gilt hier unverändert. Verschieden ist nur, was
/// darunter steht.
struct DetailView: View {
    let model: AppModel
    let item: Item
    let zurueck: () -> Void

    @State private var voll: Item?

    private var titel: Item { voll ?? item }

    var body: some View {
        Group {
            switch titel.type {
            case "Series":
                SerienView(model: model, serie: titel, zurueck: zurueck)
            case "Episode":
                // **Eine Folge bekommt keine eigene Seite** (A8). Sie trüge
                // nichts, was nicht in der Folgenliste schon steht. Also die
                // Serie nachholen und deren Seite zeigen, mit der Staffel der
                // Folge bereits gewählt.
                StaffelZiel(model: model, folge: titel, zurueck: zurueck)
            default:
                FilmView(model: model, film: titel, zurueck: zurueck)
            }
        }
        .task { if voll == nil { voll = await model.item(id: item.id) } }
    }
}

/// Der Zwischenschritt von einer Folge zur Serienseite.
struct StaffelZiel: View {
    let model: AppModel
    let folge: Item
    let zurueck: () -> Void

    @State private var serie: Item?

    var body: some View {
        Group {
            if let serie {
                SerienView(model: model, serie: serie, startStaffelID: folge.seasonId,
                           zurueck: zurueck)
            } else {
                Lader()
            }
        }
        .task {
            guard serie == nil, let id = folge.seriesId else { return }
            serie = await model.item(id: id)
        }
    }
}

// MARK: - Film

struct FilmView: View {
    let model: AppModel
    let film: Item
    let zurueck: () -> Void

    @State private var farbe = Bildfarbe()

    @State private var extras: [Item] = []
    @State private var aehnliche: [Item] = []
    @State private var versatz: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Heldenkopf(model: model, titel: film)

                VStack(alignment: .leading, spacing: 26) {
                    // Die Beschreibung steht im Kopf, wie auf dem Apple TV —
                    // hier stünde sie ein zweites Mal.
                    Besetzungsreihe(model: model, leute: film.darsteller)
                    // Extras und Ähnliches fehlten auf meiner Filmseite ganz.
                    // Reihenfolge wie auf iOS (A9).
                    Titelreihe(titel: "Extras", eintraege: extras, model: model)
                    Titelreihe(titel: "Ähnliches", eintraege: aehnliche, model: model)
                    if let quelle = film.mediaSources?.first {
                        Dateizeile(quelle: quelle)
                    }
                }
                .padding(.horizontal, Stil.randAbstand)
                .padding(.top, 26)
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        // Der Ton läuft unter dem Heldenbild noch ein Stück weiter und
        // verliert sich dann im Grundton — wie bei Apple TV, wo die ganze
        // Seite vom Bild eingefärbt wirkt statt an seiner Unterkante zu enden.
        .background(alignment: .top) {
            LinearGradient(colors: [farbe.ton, Stil.grund],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: Stil.heldHoehe + 260)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Stil.grund)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, neu in
            versatz = neu
        }
        .overlay(alignment: .top) {
            Detailkopf(titel: film.name, versatz: versatz, zurueck: zurueck)
        }
        .task { await farbe.laden(model.backdropURL(for: film)) }
        .task {
            async let a = model.extras(film)
            async let b = model.aehnliche(film)
            extras = await a
            aehnliche = await b
        }
    }
}

/// Eine waagerechte Reihe von Postern mit Überschrift — Extras, Ähnliches.
struct Titelreihe: View {
    let titel: LocalizedStringKey
    let eintraege: [Item]
    let model: AppModel

    var body: some View {
        if !eintraege.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text(titel)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Stil.schrift)
                Blätterreihe(rand: 0) {
                    ForEach(eintraege, id: \.id) { eintrag in
                        NavigationLink(value: eintrag) {
                            Posterkachel(titel: eintrag.name,
                                         zweitzeile: eintrag.productionYear.map { "\($0)" },
                                         bild: model.imageURL(for: eintrag, hochkant: true))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}


// MARK: - Der gemeinsame Kopf

/// Das Heldenbild mit allem darin: Poster, Titel, Beleg, Hauptknopf,
/// Aktionsreihe. Nicht zu verwechseln mit `Detailkopf` — das ist die Leiste
/// mit Pfeil und Titel, die beim Scrollen einblendet.
///
/// Die Reihenfolge ist die der iPhone-Fassung: Beleg → Hauptknopf →
/// Aktionsreihe. Was sich ändert, ist die Anordnung, nicht die Folge — im
/// Fenster steht das Poster **neben** dem Titel statt darüber, weil eine 1400
/// Punkt breite Spalte mit einer Zeile Text darin unlesbar wäre.
struct Heldenkopf: View {
    let model: AppModel
    let titel: Item

    @State private var plan: PlaybackPlan?
    @State private var spielbarerTitel: Item?
    @State private var merkliste = false
    @State private var gesehen = false
    @State private var mehrOffen = false
    @State private var meldung: String?
    @Environment(Abspielsteuerung.self) private var steuerung

    var body: some View {
        ZStack(alignment: .topLeading) {
            // **Rechts, nicht über die volle Breite** — wie auf dem Apple TV.
            // Das Bild ragt nach unten über die Kopfzone hinaus; seine eigene
            // Maske beendet es, deshalb wird nicht beschnitten.
            Kulisse(url: model.querbildURL(for: titel, breite: 1600)
                         ?? model.backdropURL(for: titel),
                    hoehe: Stil.heldHoehe * 1.24)

            block
                .padding(.leading, Stil.randAbstand)
                .padding(.top, Stil.inhaltOben + 34)
        }
        .frame(height: Stil.heldHoehe, alignment: .topLeading)
        .task {
            merkliste = titel.userData?.isFavorite ?? false
            gesehen = titel.userData?.played ?? false
            plan = await model.plan(for: spielbarerTitel?.id ?? titel.id)
        }
        .task(id: titel.id) {
            if titel.type == "Series" { spielbarerTitel = await model.standInSerie(titel) }
        }
    }

    /// **Kein Poster.** Auf dem Apple TV ist es weggefallen, weil es nur den
    /// Fortschrittsbalken trug — und der steht jetzt dort, wo er auf jeder
    /// anderen Kachel auch steht.
    private var block: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: titel.name)
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
                .minimumScaleFactor(0.62)

            // **Eine Zeile**, nicht drei: Jahr, Laufzeit, Bewertung,
            // Freigabe und der Beleg stehen nebeneinander. Vorher lagen
            // Nebenzeile und Beleg untereinander.
            HStack(spacing: 14) {
                Text(verbatim: angabenzeile)
                    .font(.system(size: 14))
                    .foregroundStyle(Stil.schriftLeise)
                if let bewertung = titel.communityRating {
                    HStack(spacing: 5) {
                        Image(systemName: "star.fill").font(.system(size: 10))
                        Text(verbatim: String(format: "%.1f", bewertung))
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Stil.schriftLeise)
                }
                if let freigabe = titel.officialRating { Plakette(text: freigabe) }
                if let plan {
                    HStack(spacing: 6) {
                        Image(systemName: plan.isLossless
                              ? "checkmark" : "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .heavy))
                        Text(verbatim: plan.isLossless
                             ? String(localized: "Direct Play") : plan.method.rawValue)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(plan.isLossless ? Stil.akzent : Stil.warnung)
                    .transition(.opacity)
                }
            }
            .lineLimit(1)
            .padding(.top, 12)

            // Die Beschreibung steht **im Kopf**, direkt unter den Angaben —
            // nicht weit darunter auf dem Grundton.
            if let text = titel.overview, !text.isEmpty {
                Text(verbatim: text)
                    .font(Stil.koerper)
                    .lineSpacing(3)
                    .foregroundStyle(Stil.schrift.opacity(0.62))
                    .lineLimit(3)
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(.top, 18)
            }

            knopfreihe.padding(.top, 24)
        }
    }

    /// Vier Ziele wie auf dem Apple TV: Fortsetzen, Von vorn, Merkliste,
    /// Mehr. „Gesehen" und „Trailer" sind in die Mehr-Liste gewandert —
    /// fünf beschriftete Knöpfe waren zu viel für eine Reihe.
    private var knopfreihe: some View {
        HStack(spacing: 12) {
            if let ab = (spielbarerTitel ?? titel).fortsetzenAb {
                Hauptknopf(beschriftung: "Fortsetzen") { starten(ab) }
                Nebenknopf(symbol: "arrow.counterclockwise", titel: "Von vorn") {
                    starten(0)
                }
            } else {
                Hauptknopf(beschriftung: "Abspielen") { starten(0) }
            }

            Nebenknopf(symbol: merkliste ? "bookmark.fill" : "bookmark",
                       titel: "Merkliste", aktiv: merkliste) {
                merkliste.toggle()
                Task {
                    if let grund = await model.setzeMerkliste(titel, an: merkliste) {
                        merkliste.toggle()
                        melde(grund)
                    }
                }
            }

            Nebenknopf(symbol: "ellipsis", titel: "Mehr", aktiv: mehrOffen) {
                withAnimation(Stil.zeitSprung) { mehrOffen.toggle() }
            }
            .overlay(alignment: .topLeading) {
                if mehrOffen {
                    Handlungsliste(handlungen: mehrHandlungen, offen: $mehrOffen)
                        .offset(x: -206, y: Stil.hauptknopfHoehe + 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            if let meldung { Hinweisstreifen(text: meldung) }
            Spacer(minLength: 0)
        }
    }

    private var angabenzeile: String {
        var teile: [String] = []
        if let jahr = titel.productionYear { teile.append(String(jahr)) }
        if let sekunden = titel.runtimeSeconds, sekunden > 0 { teile.append(laufzeit(sekunden)) }
        if let genres = titel.genres, !genres.isEmpty {
            teile.append(genres.prefix(2).joined(separator: ", "))
        }
        return teile.joined(separator: " · ")
    }

    private func starten(_ ab: Double) {
        steuerung.starte(spielbarerTitel ?? titel, ab: ab)
    }

    /// Dieselben Handlungen wie auf den anderen Plattformen, aus
    /// `Titelhandlungen` — dazu „Gesehen" und „Trailer", die auf dem Apple TV
    /// ebenfalls hier stehen statt in der Knopfreihe.
    private var mehrHandlungen: [Titelhandlung] {
        var liste: [Titelhandlung] = [
            .init(symbol: gesehen ? "checkmark.circle.fill" : "checkmark.circle",
                  text: gesehen ? "Als ungesehen markieren" : "Als gesehen markieren") {
                gesehen.toggle()
                Task {
                    if let grund = await model.setzeGesehen(titel, an: gesehen) {
                        gesehen.toggle()
                        melde(grund)
                    }
                }
            },
            .init(symbol: "film", text: "Trailer") { trailerStarten() },
        ]
        if titel.type == "Series" {
            liste += Titelhandlungen.fuerSerie(
                titel, stand: spielbarerTitel, staffel: nil, model: model,
                folgeStarten: { folge, ab in steuerung.starte(folge, ab: ab) },
                melden: { melde($0) }, auffrischen: { await auffrischen() })
        } else {
            liste += Titelhandlungen.fuerFilm(
                titel, plan: plan, model: model,
                starten: { ab in steuerung.starte(titel, ab: ab) },
                melden: { melde($0) }, auffrischen: { await auffrischen() })
        }
        return liste
    }

    private func trailerStarten() {
        Task {
            if let film = await model.trailer(zu: titel) {
                steuerung.starte(film, ab: 0)
                return
            }
            if let adresse = titel.remoteTrailers?.compactMap(\.url).first,
               let ziel = URL(string: adresse) {
                NSWorkspace.shared.open(ziel)
                return
            }
            melde(String(localized: "Für diesen Titel liegt kein Trailer vor."))
        }
    }

    private func auffrischen() async {
        if titel.type == "Series" { spielbarerTitel = await model.standInSerie(titel) }
        plan = await model.plan(for: spielbarerTitel?.id ?? titel.id)
    }

    private func melde(_ text: String) {
        meldung = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { meldung = nil }
        }
    }
}

// MARK: - Bausteine der Detailseiten

struct Beschreibung: View {
    let text: String?
    var body: some View {
        if let text, !text.isEmpty {
            Text(verbatim: text)
                .font(Stil.koerper)
                .lineSpacing(3)
                .foregroundStyle(Stil.schrift.opacity(0.86))
                .frame(maxWidth: 900, alignment: .leading)
        }
    }
}

struct Besetzungsreihe: View {
    let model: AppModel
    let leute: [Person]

    var body: some View {
        if !leute.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Besetzung")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Stil.schrift)
                Blätterreihe(rand: 0, breiteJeStueck: 84 + 18) {
                    ForEach(leute, id: \.id) { person in
                        Kopfbild(name: person.name, rolle: person.role,
                                 bild: model.personBild(person))
                    }
                }
            }
        }
    }
}


/// Das Heldenbild mit seinen zwei Verläufen.
///
/// Anders als auf der Startseite haben die Verläufe hier eine Aufgabe: oben
/// hält er das Bild von den Fensterknöpfen weg, unten führt er es in den
/// Grundton. Der untere ist bewusst flach — ein starker Verlauf frisst das
/// Bild auf.
struct Bildhintergrund: View {
    let bild: URL?
    /// Der Ton, in den das Bild unten übergeht — aus dem Bild selbst.
    var ton: Color = Stil.grund

    var body: some View {
        ZStack {
            Stil.flaeche
            if let bild {
                AsyncImage(url: bild) { stufe in
                    if let abbild = stufe.image {
                        abbild.resizable().aspectRatio(contentMode: .fill)
                    }
                }
            }
        }
        .clipped()
        .overlay(alignment: .top) {
            LinearGradient(colors: [ton.opacity(0.85), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 110)
        }
        // **Der Auslauf muss tragen, worauf Text steht.** Auf dem iPhone ist
        // das Heldenbild 300 hoch und trägt nur Titel und Nebenzeile; hier
        // sind es 420 mit Poster, Titel, Beleg, Hauptknopf und Aktionsreihe.
        // Ein 130 Punkt hoher Auslauf reichte deshalb nicht — die Buchstaben
        // standen auf hellem Bild. Stützpunkte wie `Heldauslauf`, nur über
        // die untere Hälfte statt über 130 Punkt.
        .overlay(alignment: .bottom) {
            LinearGradient(stops: [
                .init(color: ton.opacity(0),    location: 0),
                .init(color: ton.opacity(0.30), location: 0.28),
                .init(color: ton.opacity(0.72), location: 0.55),
                .init(color: ton.opacity(0.94), location: 0.80),
                .init(color: ton,               location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: Stil.heldHoehe * 0.92)
            .allowsHitTesting(false)
        }
    }
}

struct Kopfbild: View {
    let name: String
    let rolle: String?
    let bild: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                Stil.flaeche
                if let bild {
                    AsyncImage(url: bild) { stufe in
                        if let abbild = stufe.image {
                            abbild.resizable().aspectRatio(contentMode: .fill)
                        }
                    }
                }
            }
            .frame(width: 76, height: 76)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name)
                    .font(Stil.zweitzeile.weight(.medium))
                    .foregroundStyle(Stil.schrift)
                    .lineLimit(2)
                if let rolle {
                    Text(verbatim: rolle)
                        .font(Stil.zweitzeile)
                        .foregroundStyle(Stil.schriftLeise)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: 84, alignment: .leading)
    }
}

/// Ganz unten: was für eine Datei das eigentlich ist. Sie beantwortet eine
/// Frage, die man erst später stellt.
///
/// Die Texte kommen aus `Dateiangaben` in `Sources/Shared` — Container,
/// Codec und Untertitel sind auf allen Plattformen dieselbe Auskunft. Meine
/// erste Fassung stellte sie selbst zusammen und ließ Codec und Untertitel
/// weg.
struct Dateizeile: View {
    let quelle: MediaSource

    var body: some View {
        HStack(spacing: 22) {
            ForEach(angaben, id: \.self) { text in Text(verbatim: text) }
        }
        .font(Stil.zweitzeile)
        .foregroundStyle(Stil.schriftSehrLeise)
        .padding(.top, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Stil.linie).frame(height: 1) }
    }

    private var angaben: [String] {
        var zeilen: [String] = []
        if let behaelter = Dateiangaben.container(quelle) { zeilen.append(behaelter) }
        if let spur = Dateiangaben.videospur(quelle) {
            zeilen.append(Dateiangaben.video(spur, quelle))
        }
        zeilen.append(Dateiangaben.groesse(quelle))
        let ut = Dateiangaben.untertitel(Dateiangaben.untertitelspuren(quelle))
        if !ut.isEmpty { zeilen.append(ut) }
        return zeilen.filter { !$0.isEmpty }
    }
}
