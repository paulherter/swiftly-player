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

    @State private var extras: [Item] = []
    @State private var aehnliche: [Item] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Detailkopf(model: model, titel: film)

                VStack(alignment: .leading, spacing: 26) {
                    Beschreibung(text: film.overview)
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
        .overlay(alignment: .topLeading) { Rueckpfeil(zurueck: zurueck) }
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
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Stil.kachelAbstand) {
                        ForEach(eintraege, id: \.id) { eintrag in
                            NavigationLink(value: eintrag) {
                                Posterkachel(titel: eintrag.name,
                                             zweitzeile: eintrag.productionYear.map { "\($0)" },
                                             bild: model.imageURL(for: eintrag, hochkant: true))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .scrollIndicators(.never)
            }
        }
    }
}

/// Der Weg zurück: eigener Pfeil oben links **im Bild**, nicht in der
/// Titelleiste (E9). Er hält Abstand zur Fensterampel, die links davon sitzt.
struct Rueckpfeil: View {
    let zurueck: () -> Void

    var body: some View {
        Aktionsknopf(symbol: "chevron.left", titel: "Zurück", auswahl: zurueck)
            .background(Circle().fill(.black.opacity(0.35)))
            .padding(.leading, 92)
            .padding(.top, 12)
    }
}

// MARK: - Der gemeinsame Kopf

/// Heldenbild, Poster, Titel, Beleg, Hauptknopf, Aktionsreihe.
///
/// Die Reihenfolge ist die der iPhone-Fassung: Beleg → Hauptknopf →
/// Aktionsreihe. Was sich ändert, ist die Anordnung, nicht die Folge — im
/// Fenster steht das Poster **neben** dem Titel statt darüber, weil eine 1400
/// Punkt breite Spalte mit einer Zeile Text darin unlesbar wäre.
struct Detailkopf: View {
    let model: AppModel
    let titel: Item

    @State private var merkliste = false
    @State private var gesehen = false
    @State private var plan: PlaybackPlan?
    /// Bei einer Serie die Folge, die der Hauptknopf meint.
    @State private var spielbarerTitel: Item?
    @State private var mehrOffen = false
    @State private var meldung: String?
    @Environment(Abspielsteuerung.self) private var steuerung

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Bildhintergrund(bild: model.backdropURL(for: titel))
                .frame(height: Stil.heldHoehe)

            HStack(alignment: .bottom, spacing: 24) {
                Bildflaeche(bild: model.imageURL(for: titel, hochkant: true),
                            breite: 180, hoehe: 270)
                    .shadow(color: .black.opacity(0.55), radius: 22, y: 18)

                angaben.padding(.bottom, 6)
            }
            .padding(.horizontal, Stil.randAbstand)
            .padding(.bottom, 26)
        }
        .frame(height: Stil.heldHoehe)
        .task {
            merkliste = titel.userData?.isFavorite ?? false
            gesehen = titel.userData?.played ?? false
            // Was der Server mit dieser Datei vorhat — dasselbe, was der
            // Player später bekommt.
            plan = await model.plan(for: spielbarerTitel?.id ?? titel.id)
        }
        .task(id: titel.id) {
            // Bei einer Serie startet der Hauptknopf **nicht** die Serie,
            // sondern die Folge, die der Server nennt: angefangene an ihrer
            // Stelle, sonst die nächste ungesehene, sonst Folge 1.
            if titel.type == "Series" { spielbarerTitel = await model.standInSerie(titel) }
        }
    }

    private var angaben: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: titel.name)
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(Stil.schrift)
                .lineLimit(2)

            // Jahr, Laufzeit und Genre kommen aus `Titelangaben.nebenzeile`
            // — dieselbe Zeile wie auf allen anderen Plattformen. Ich hatte
            // sie mir selbst zusammengesetzt und dabei die Genres vergessen.
            Text(verbatim: titel.nebenzeile)
                .font(.system(size: 14))
                .foregroundStyle(Stil.schriftLeise)
                .lineLimit(1)
                .padding(.top, 10)

            // Der stille Normalfall: läuft alles verlustfrei, steht hier
            // „Direct Play" im Akzent, **ohne** Erklärung. Nur die Abweichung
            // meldet sich lauter — in Warnorange und mit Grund.
            //
            // Vorher stand hier fest verdrahtet „Direct Play". Das ist genau
            // das Versprechen der App, und es einfach zu behaupten wäre die
            // schlimmste Sorte falsch: man hätte nie erfahren, dass der Server
            // rechnet.
            HStack(spacing: 14) {
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
                // Bewertung und Freigabe stehen auf iOS in derselben Zeile
                // wie der Beleg (`Belegzeile`), nicht oben bei Jahr und
                // Laufzeit. Ich hatte die Freigabe nach oben gesetzt.
                if let bewertung = titel.communityRating {
                    HStack(spacing: 5) {
                        Image(systemName: "star.fill").font(.system(size: 10))
                        Text(verbatim: String(format: "%.1f", bewertung))
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Stil.schriftLeise)
                }
                if let freigabe = titel.officialRating { Plakette(text: freigabe) }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.top, 12)

            HStack(spacing: 12) {
                Hauptknopf(beschriftung: hauptknopfText, kuerzel: "⏎") {
                    starten()
                }
                Aktionsknopf(symbol: merkliste ? "checkmark" : "plus",
                             titel: "Merkliste", an: merkliste) {
                    merkliste.toggle()
                    Task {
                        // Zurückdrehen, wenn der Server nein sagt — sonst
                        // bliebe die Anzeige stehen und löge.
                        if let grund = await model.setzeMerkliste(titel, an: merkliste) {
                            merkliste.toggle()
                            melde(grund)
                        }
                    }
                }
                Aktionsknopf(symbol: "film", titel: "Trailer") { trailerStarten() }
                Aktionsknopf(symbol: gesehen ? "checkmark.circle.fill" : "checkmark.circle",
                             titel: "Gesehen", an: gesehen) {
                    gesehen.toggle()
                    Task {
                        if let grund = await model.setzeGesehen(titel, an: gesehen) {
                            gesehen.toggle()
                            melde(grund)
                        }
                    }
                }
                Aktionsknopf(symbol: "ellipsis", titel: "Mehr", an: mehrOffen) {
                    withAnimation(Stil.zeitSprung) { mehrOffen.toggle() }
                }
                if let meldung {
                    Hinweisstreifen(text: meldung)
                }
            }
            .padding(.top, 18)
            // Die Liste klappt direkt unter dem Knopf auf — kein Blatt, kein
            // eigenes Fenster. Der Überlagerung wegen, damit sie den Kopf
            // nicht auseinanderschiebt.
            .overlay(alignment: .bottomLeading) {
                if mehrOffen {
                    Handlungsliste(handlungen: mehrHandlungen, offen: $mehrOffen)
                        .offset(y: 52)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func starten() {
        steuerung.starte(spielbarerTitel ?? titel)
    }

    /// „Fortsetzen", wenn schon etwas läuft — sonst „Abspielen".
    private var hauptknopfText: LocalizedStringKey {
        (spielbarerTitel ?? titel).fortsetzenAb != nil ? "Fortsetzen" : "Abspielen"
    }


    /// Die Einträge kommen aus `Titelhandlungen` — derselbe Erzeuger wie auf
    /// dem iPhone (VERHALTEN.md D7). Meine erste Fassung stellte sie selbst
    /// zusammen und kannte weder Trailer noch „Nächste Folge abspielen".
    private var mehrHandlungen: [Titelhandlung] {
        if titel.type == "Series" {
            return Titelhandlungen.fuerSerie(
                titel, stand: spielbarerTitel, staffel: nil, model: model,
                folgeStarten: { folge, ab in steuerung.starte(folge, ab: ab) },
                melden: { melde($0) },
                auffrischen: { await auffrischen() })
        }
        return Titelhandlungen.fuerFilm(
            titel, plan: plan, model: model,
            starten: { ab in steuerung.starte(titel, ab: ab) },
            melden: { melde($0) },
            auffrischen: { await auffrischen() })
    }

    /// Erst der Trailer als Datei vom Server, sonst der verlinkte im Browser.
    /// Gibt es keinen, sagt es das — dieselbe Reihenfolge wie auf dem iPhone.
    private func trailerStarten() {
        Task {
            if let film = await model.trailer(zu: titel) {
                steuerung.starte(film, ab: 0)
                return
            }
            if let adresse = titel.remoteTrailers?.compactMap(\.url).first,
               let ziel = URL(string: adresse) {
                // Auf dem iPhone `UIApplication.shared.open` — auf dem Mac
                // gibt es das nicht, die Entsprechung ist NSWorkspace.
                NSWorkspace.shared.open(ziel)
                return
            }
            melde(String(localized: "Für diesen Titel liegt kein Trailer vor."))
        }
    }

    /// Nach „Fortschritt zurücksetzen" den neuen Stand holen — sonst zeigt der
    /// Hauptknopf weiter „Fortsetzen" und der Beleg den alten Plan.
    private func auffrischen() async {
        if titel.type == "Series" {
            spielbarerTitel = await model.standInSerie(titel)
        }
        plan = await model.plan(for: spielbarerTitel?.id ?? titel.id)
    }

    /// Drei Sekunden, dann von selbst weg — wie der Hinweisstreifen auf iOS.
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
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(leute, id: \.id) { person in
                            Kopfbild(name: person.name, rolle: person.role,
                                     bild: model.personBild(person))
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.never)
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
            LinearGradient(colors: [Stil.grund.opacity(0.85), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 110)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, Stil.grund],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 130)
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
