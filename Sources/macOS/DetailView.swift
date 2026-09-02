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
    @Environment(\.seiteRuht) private var ruht

    /// **Der volle Satz erst, wenn die Seite steht.**
    ///
    /// `model.item(id:)` kommt nach ein bis vier Zehntelsekunden zurück —
    /// also mitten im Hereinfahren. Dann wurde der ganze Unterbau mit anderen
    /// Daten neu gezeichnet, während er unterwegs war. Das war das kurze
    /// Zucken beim Öffnen eines Films.
    private var titel: Item { ruht ? (voll ?? item) : item }

    /// Nur zum Nachmessen: welchen Weg ein Klick nimmt.
    private func protokolliert(_ art: String?) -> String? {
        if Ruckelwache.an { Protokoll.schreib("Detailseite: \(item.name) ist \(art ?? "?")") }
        return art
    }

    var body: some View {
        Group {
            // **Nach `item.type` verzweigen, nicht nach `titel.type`.** Die
            // Art steht schon in der Liste; nach dem nachgeladenen Satz zu
            // verzweigen hiess, den Zweig unterwegs wechseln zu können — und
            // damit die halbe Seite wegzuwerfen und neu zu bauen.
            switch protokolliert(item.type) {
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

    /// **Was vorgeholt ist, steht sofort** — dann gibt es die leere Seite gar
    /// nicht erst. Nachgereicht käme der Wert zu spät: der leere Durchgang
    /// hat dann schon stattgefunden, und der ist das, was man sieht.
    @MainActor init(model: AppModel, folge: Item, zurueck: @escaping () -> Void) {
        self.model = model
        self.folge = folge
        self.zurueck = zurueck
        _serie = State(initialValue: Seriencache.geteilt.serie(fuer: folge))
    }

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
            let start = Date()
            let geholt = await model.item(id: id)
            if let geholt { Seriencache.geteilt.merken(geholt) }
            serie = geholt
            if Ruckelwache.an {
                Protokoll.schreib("StaffelZiel: leere Seite \(Int(Date().timeIntervalSince(start) * 1000)) ms lang")
            }
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
        // **Die milchige Leiste am oberen Rand.** macOS 26 legt sie von sich
        // aus über jede Scrollfläche — sie war nie in unserem Code, und
        // deshalb habe ich zweimal an der falschen Stelle gesucht. Über dem
        // Bild verlor sie sich, links auf blankem Grund stand sie als Balken.
        //
        // E4 wieder: was das Rahmenwerk ungefragt dazustellt, gehört ebenso
        // abgestellt wie das, was man selbst hinschreibt.
        .ohneKanteneffekt()
        // **Der Inhalt läuft bis unter die Titelleiste durch.** SwiftUI rückt
        // ihn sonst um deren Sicherheitsbereich ein, und über dem Bild stand
        // ein dunkler Streifen. Die iPhone-Fassung tut dasselbe.

        // **Auch hier, nicht nur am Stapel.** `NavigationStack` bekommt den
        // Riegel in `HauptView`; für eine geschobene Ansicht stellt SwiftUI
        // den Werkzeugleisten-Grund trotzdem wieder dazu — als milchige
        // Leiste über dem Bild. E4 gilt auch für das, was das Rahmenwerk
        // ungefragt beisteuert.
        .toolbar(.hidden)
        .toolbarBackground(.hidden, for: .windowToolbar)
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
    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich
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
                        Button { navigator.oeffne(.titel(eintrag), in: bereich) } label: {
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
                    hoehe: Stil.heldHoehe * 1.62)

            block
                .padding(.leading, Stil.randAbstand)
                .padding(.top, Stil.titelHoehe + 98)
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
    ///
    /// **Jede Zeile hat eine feste Höhe.** Titel, Angaben, Beschreibung und
    /// Knopfreihe stehen damit auf **jeder** Filmseite an derselben Stelle,
    /// egal wie lang der Titel ist oder wie viel Beschreibung der Server
    /// liefert. Ohne das wandern Knöpfe und Reihen beim Blättern von Film zu
    /// Film, und die Seite wirkt jedes Mal anders gebaut.
    ///
    /// Dieselbe Überlegung wie `Stil.auskunftHoehe` auf dem Fernseher: dort
    /// ist die Höhe fest, und ein langer Titel schrumpft, statt die Seite zu
    /// verschieben.
    private var block: some View {
        // **Feste Stellen statt fester Höhen.**
        //
        // Ein Stapel mit festen Höhen je Zeile *sollte* reichen — tut es aber
        // offenbar nicht: die Knöpfe wanderten weiter, je nachdem was der
        // Server lieferte. Statt weiter zu raten, wo eine Zeile doch noch
        // wächst, steht jede Zeile jetzt an einer **ausgerechneten Stelle**.
        // Was darin zu groß wird, wird abgeschnitten und verschiebt nichts.
        //
        //     0    Titel        42
        //     54   Angaben      20
        //     92   Beschreibung 66   (drei Zeilen)
        //     182  Knopfreihe   48
        //     230  Ende
        ZStack(alignment: .topLeading) {
            Text(verbatim: titel.name)
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
                // Ein langer Titel schrumpft, statt die Seite zu verschieben.
                .minimumScaleFactor(0.62)
                .frame(width: 640, height: 42, alignment: .leading)
                .offset(y: 0)

            angabenReihe
                .frame(width: 640, height: 20, alignment: .leading)
                .clipped()
                .offset(y: 54)

            Text(verbatim: titel.overview ?? "")
                .font(Stil.koerper)
                .lineSpacing(3)
                .foregroundStyle(Stil.schrift.opacity(0.62))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(width: 640, height: 66, alignment: .topLeading)
                .clipped()
                .offset(y: 92)

            knopfreihe
                .frame(height: Stil.hauptknopfHoehe, alignment: .leading)
                .offset(y: 182)
        }
        .frame(width: 640, height: 230, alignment: .topLeading)
    }

    /// Jahr, Laufzeit, Genres, Bewertung, Freigabe und der Beleg — **eine
    /// Zeile**, nicht drei.
    private var angabenReihe: some View {
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
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Vier Ziele wie auf dem Apple TV: Fortsetzen, Von vorn, Merkliste,
    /// Mehr. „Gesehen" und „Trailer" sind in die Mehr-Liste gewandert —
    /// fünf beschriftete Knöpfe waren zu viel für eine Reihe.
    private var knopfreihe: some View {
        HStack(spacing: 12) {
            // **Feste Breite für den Hauptknopf, aber kein Platzhalter.**
            //
            // Die feste Breite bleibt: sonst wüchse der Knopf mit seiner
            // Beschriftung — „Fortsetzen" ist länger als „Abspielen" — und
            // schöbe alles dahinter. „Von vorn" gibt es dagegen nur bei
            // angefangenen Titeln, und wo es das nicht gibt, rückt der Rest
            // auf. Eine leere Lücke stehen zu lassen wäre schlimmer als der
            // kleine Versatz.
            if let ab = (spielbarerTitel ?? titel).fortsetzenAb {
                Hauptknopf(beschriftung: "Fortsetzen") { starten(ab) }
                    .frame(width: Stil.hauptknopfBreite)
                Nebenknopf(symbol: "arrow.counterclockwise", titel: "Von vorn") {
                    starten(0)
                }
            } else {
                Hauptknopf(beschriftung: "Abspielen") { starten(0) }
                    .frame(width: Stil.hauptknopfBreite)
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



struct Kopfbild: View {
    let name: String
    let rolle: String?
    let bild: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                Stil.flaeche
                Netzbild(url: bild)
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
