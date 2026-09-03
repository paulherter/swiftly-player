import JellyfinKit
import SwiftUI

/// Die Bausteine für den Mac. Keine Apple-Standardsteuerelemente — kein
/// `List`, `Toggle`, `Picker`, `Menu`, `Slider`. Dieselbe Regel wie auf iPhone
/// und Fernseher, aus demselben Grund: sie bringen eigene Maße, eigene Ecken
/// und eigenes Material mit.
///
/// Neu gegenüber den anderen Plattformen ist nur eines: der **Schwebezustand**.
/// Ein Zeiger steht über einer Fläche, bevor er sie anklickt — dieser Zustand
/// existiert weder auf dem iPhone noch mit einer Fernbedienung.

// MARK: - Seitenleiste

/// Eine Zeile in der Seitenleiste. Tritt an die Stelle der Leiste unten:
/// dort war der Daumen die Grenze, hier die Fensterhöhe.
struct Seitenleistenzeile: View {
    let symbol: String
    let beschriftung: LocalizedStringKey
    let aktiv: Bool
    let auswahl: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: auswahl) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 17)
                Text(beschriftung)
                    .font(Stil.koerper.weight(.medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: Stil.zeileHoehe)
            .foregroundStyle(vordergrund)
            .background(hintergrund, in: RoundedRectangle(cornerRadius: Stil.ecke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
        .accessibilityAddTraits(aktiv ? [.isButton, .isSelected] : .isButton)
    }

    private var vordergrund: Color {
        if aktiv { return Stil.akzent }
        return schwebt ? Stil.schrift : Stil.schriftLeise
    }

    /// Der Akzent trägt Auswahl — das ist dieselbe Regel wie auf iOS, wo der
    /// aktive Bereich der Leiste ihn ebenfalls trägt. Der Schwebezustand
    /// bekommt bewusst nur Weiß: er zeigt „hier steht der Zeiger", keine Wahl.
    private var hintergrund: Color {
        if aktiv { return Stil.akzent.opacity(0.10) }
        return schwebt ? Stil.schrift.opacity(0.06) : .clear
    }
}

/// Überschrift einer Gruppe in der Seitenleiste.
struct Seitenleistenrubrik: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(Stil.rubrik)
            .tracking(0.7)
            .textCase(.uppercase)
            .foregroundStyle(Stil.schriftSehrLeise)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Chip

/// Filter- und Sortierchip. Aktiv ist er weiß mit schwarzer Schrift — dieselbe
/// Form wie der Hauptknopf, eine Nummer kleiner.
struct Chip: View {
    let beschriftung: String
    var symbol: String?
    let aktiv: Bool
    let auswahl: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: auswahl) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                }
                Text(beschriftung).font(.system(size: 13, weight: aktiv ? .semibold : .regular))
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .foregroundStyle(aktiv ? Stil.grund : (schwebt ? Stil.schrift : Stil.schriftLeise))
            .background(aktiv ? Stil.schrift : (schwebt ? Stil.schrift.opacity(0.06) : .clear),
                        in: Capsule())
            .overlay(Capsule().strokeBorder(aktiv ? .clear : Stil.rand, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { schwebt = $0 }
        .animation(Stil.zeitUmschalten, value: aktiv)
        .animation(Stil.zeitSchweben, value: schwebt)
    }
}

// MARK: - Knöpfe

/// Der eine Hauptknopf je Seite: weiß, schwarze Schrift, 48 hoch.
///
/// Auf dem iPhone läuft er über die volle Breite. Hier nicht — die Breite war
/// eine Antwort auf den Daumen, und der Zeiger trifft auch einen schmalen
/// Knopf. Ein 1200 Punkt breiter Knopf sähe zudem aus wie ein Versehen.
struct Hauptknopf: View {
    let beschriftung: LocalizedStringKey
    var symbol: String = "play.fill"
    var kuerzel: String?
    let auswahl: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: auswahl) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                Text(beschriftung).font(.system(size: 16, weight: .semibold))
                if let kuerzel {
                    Text(kuerzel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Stil.grund.opacity(0.42))
                }
            }
            .padding(.horizontal, 30)
            .frame(maxWidth: .infinity)
            .frame(height: Stil.hauptknopfHoehe)
            .foregroundStyle(Stil.grund)
            .background(schwebt ? Stil.schrift.opacity(0.88) : Stil.schrift,
                        in: RoundedRectangle(cornerRadius: Stil.ecke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
    }
}

/// Runder Aktionsknopf neben dem Hauptknopf — Merkliste, Trailer, Gesehen, Mehr.
///
/// Der `titel` steht nicht im Bild, sondern ist der Name für VoiceOver (E8).
/// Ein Knopf, der nur ein Symbol trägt, heißt sonst „Taste" und sonst nichts.
struct Aktionsknopf: View {
    let symbol: String
    var titel: LocalizedStringKey?
    var an: Bool = false
    /// Die Umrandung. Sie gehört dorthin, wo der Knopf auf ruhigem Grund
    /// steht und sonst nicht als Knopf zu erkennen wäre — in einer Zeile,
    /// auf einer Fläche. **Über einem Filmbild nicht:** dort ist der Knopf
    /// ohnehin der einzige Kreis weit und breit, und der Ring liegt als
    /// Fremdkörper im Bild.
    var rand: Bool = true
    let auswahl: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: auswahl) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: Stil.knopfRund, height: Stil.knopfRund)
                .foregroundStyle(an ? Stil.akzent : Stil.schrift.opacity(0.8))
                .background(schwebt ? Stil.schrift.opacity(0.08) : .clear, in: Circle())
                .overlay { if rand { Circle().strokeBorder(Stil.rand, lineWidth: 1) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
        .accessibilityLabel(titel.map { Text($0) } ?? Text(verbatim: symbol))
        .accessibilityAddTraits(an ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Kacheln

/// **`auswahl` ist wahlweise.** Ohne sie zeichnet die Kachel sich nur, ohne
/// eigenen Knopf — dann kann sie als Beschriftung in einem `NavigationLink`
/// stehen. Ein Knopf **in** einem Knopf schluckt den Klick: der innere nimmt
/// ihn an und tut nichts, der äußere erfährt nie davon. Genau daran waren
/// sämtliche Wege auf die Detailseiten tot.
///
/// Poster, 2 : 3. Beim Schweben vergrößert es sich leicht — **keine
/// Akzentumrandung:** der Akzent trägt Fortschritt, Auswahl und den
/// Direct-Play-Beleg (E2), und „hier steht der Zeiger" ist keine Auswahl.
struct Posterkachel: View {
    let titel: String
    let zweitzeile: String?
    let bild: URL?
    var fortschritt: Double?
    var auswahl: (() -> Void)?
    /// `nil`, wenn es keine Übersicht dazu gibt (A6).
    var uebersicht: (() -> Void)?
    /// Wird beim Überfahren gerufen — siehe `Seriencache.vorholen(_:mit:)`.
    var vorholen: (() -> Void)?

    @State private var schwebt = false {
        didSet { if schwebt, !oldValue { vorholen?() } }
    }

    var body: some View {
        Kachelhuelle(auswahl: auswahl, schwebt: $schwebt,
                     name: [titel, zweitzeile].compactMap { $0 }.joined(separator: ", ")) {
            VStack(alignment: .leading, spacing: 8) {
                Bildflaeche(bild: bild, breite: Stil.kachelBreite, hoehe: Stil.kachelHoehe,
                            fortschritt: fortschritt)
                    .scaleEffect(schwebt ? 1.04 : 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: titel)
                        .font(Stil.kachelTitel)
                        .foregroundStyle(Stil.schrift)
                        .lineLimit(1)
                    if let zweitzeile {
                        Text(verbatim: zweitzeile)
                            .font(Stil.zweitzeile)
                            .foregroundStyle(Stil.schriftLeise)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: Stil.kachelBreite, alignment: .leading)
        }
        .kontextmenue(uebersicht)
    }
}

/// Querkachel, 16 : 9 — nur für „Weiterschauen" und „Nächste Folge".
///
/// Ein Klick startet sofort (A1/A2). Der Weg zur Übersicht führt über die
/// rechte Maustaste (A6).
struct Querkachel: View {
    let titel: String
    let zweitzeile: String?
    let bild: URL?
    var fortschritt: Double?
    var auswahl: (() -> Void)?
    var uebersicht: (() -> Void)?
    /// Wird beim Überfahren gerufen — siehe `Seriencache.vorholen(_:mit:)`.
    var vorholen: (() -> Void)?

    @State private var schwebt = false {
        didSet { if schwebt, !oldValue { vorholen?() } }
    }

    var body: some View {
        Kachelhuelle(auswahl: auswahl, schwebt: $schwebt,
                     name: [titel, zweitzeile].compactMap { $0 }.joined(separator: ", ")) {
            VStack(alignment: .leading, spacing: 8) {
                Bildflaeche(bild: bild, breite: Stil.querBreite, hoehe: Stil.querHoehe,
                            fortschritt: fortschritt)
                    .scaleEffect(schwebt ? 1.04 : 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: titel)
                        .font(Stil.kachelTitel).foregroundStyle(Stil.schrift).lineLimit(1)
                    if let zweitzeile {
                        Text(verbatim: zweitzeile)
                            .font(Stil.zweitzeile).foregroundStyle(Stil.schriftLeise).lineLimit(1)
                    }
                }
            }
            .frame(width: Stil.querBreite, alignment: .leading)
        }
        .kontextmenue(uebersicht)
    }
}

/// Die Hülle beider Kacheln: Knopf nur, wenn es einen eigenen Klick gibt.
private struct Kachelhuelle<Inhalt: View>: View {
    let auswahl: (() -> Void)?
    @Binding var schwebt: Bool
    let name: String
    @ViewBuilder let inhalt: Inhalt

    var body: some View {
        Group {
            if let auswahl {
                Button(action: auswahl) { inhalt.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
            } else {
                inhalt.contentShape(Rectangle())
            }
        }
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityAddTraits(.isButton)
    }
}

/// Das Kontextmenü einer Kachel: der Weg zur Übersicht (A6).
///
/// `.contextMenu` ist Systemchrom, das nur beim Rechtsklick erscheint und
/// nichts in die Fläche einbringt — anders als `Menu`, das als Steuerelement
/// im Aufbau stünde.
extension View {
    @ViewBuilder
    func kontextmenue(_ uebersicht: (() -> Void)?) -> some View {
        if let uebersicht {
            contextMenu {
                Button("Übersicht öffnen", systemImage: "info.circle", action: uebersicht)
            }
        } else {
            self
        }
    }
}

/// Die Bildfläche einer Kachel samt Fortschritt.
///
/// Der Fortschritt liegt **in** der Maske, nicht als Auflage darüber — sonst
/// stehen seine eckigen Enden über die runden Ecken hinaus. Das ist einer der
/// Stolpersteine, die auf iOS schon einmal bezahlt wurden.
struct Bildflaeche: View {
    let bild: URL?
    let breite: CGFloat
    let hoehe: CGFloat
    var fortschritt: Double?

    var body: some View {
        ZStack(alignment: .bottom) {
            Stil.flaeche
            Netzbild(url: bild)
            if let fortschritt, fortschritt > 0 {
                GeometryReader { raum in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Stil.schrift.opacity(0.16))
                        Rectangle().fill(Stil.akzent)
                            .frame(width: raum.size.width * min(max(fortschritt, 0), 1))
                    }
                }
                .frame(height: 3)
            }
        }
        .frame(width: breite, height: hoehe)
        .clipShape(RoundedRectangle(cornerRadius: Stil.eckeKachel))
    }
}

// MARK: - Zustände



/// Fehler und Leeres stehen dort, wo sie entstehen — kein Hinweisfenster.
/// Dieselbe Regel wie auf dem iPhone.
struct Leerzustand: View {
    let symbol: String
    let titel: LocalizedStringKey
    var text: LocalizedStringKey?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Stil.schriftSehrLeise)
            Text(titel)
                .font(Stil.koerper.weight(.medium))
                .foregroundStyle(Stil.schriftLeise)
            if let text {
                Text(text)
                    .font(Stil.zweitzeile)
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Handlungsliste

/// Was auf dem iPhone das Blatt von unten ist.
///
/// Der Inhalt kommt aus `Titelhandlung` in `Sources/Shared` und ist auf allen
/// Plattformen derselbe — nur die Darreichung ist eigen. Hier klappt die Liste
/// **an Ort und Stelle** auf, direkt unter dem Knopf: „Auswahl bleibt am Ort",
/// dieselbe Regel wie bei der Staffelpille. Ein Blatt von unten wäre auf dem
/// Mac ein Fremdkörper, ein `Menu` bringt Systemmaße mit.
struct Handlungsliste: View {
    let handlungen: [Titelhandlung]
    @Binding var offen: Bool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(handlungen) { handlung in
                Handlungszeile(handlung: handlung) {
                    handlung.tun()
                    withAnimation(Stil.zeitSprung) { offen = false }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: 260, alignment: .leading)
        .background(Stil.erhoeht, in: RoundedRectangle(cornerRadius: Stil.eckeFeld))
        .overlay(RoundedRectangle(cornerRadius: Stil.eckeFeld)
            .strokeBorder(Stil.rand, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
    }
}

struct Handlungszeile: View {
    let handlung: Titelhandlung
    let auswahl: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: auswahl) {
            HStack(spacing: 10) {
                Image(systemName: handlung.symbol)
                    .font(.system(size: 14))
                    .frame(width: 18)
                Text(handlung.text).font(Stil.koerper)
                Spacer(minLength: 0)
            }
            .foregroundStyle(handlung.warnend ? Stil.warnung : Stil.schrift)
            .padding(.horizontal, 12)
            .frame(height: Stil.zeileHoehe)
            .background(schwebt ? Stil.schrift.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { schwebt = $0 }
    }
}

/// Eine kurze Meldung, die sich nach drei Sekunden von selbst zurückzieht.
/// Fehler stehen dort, wo sie entstehen — kein Hinweisfenster.
struct Hinweisstreifen: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(Stil.zweitzeile)
            .foregroundStyle(Stil.schrift)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Stil.erhoeht, in: Capsule())
            .overlay(Capsule().strokeBorder(Stil.rand, lineWidth: 1))
    }
}

// MARK: - Detailseite

/// Ein Knopf der Aktionsreihe: Kreis mit Symbol, **Beschriftung darunter**.
///
/// Anatomie wörtlich aus `Aktionsknopf` in `Sources/Shared/Stil.swift`:
/// Kreis 44, Symbol 18 medium, gefüllt mit Weiß 9 %, aktiv im Akzent mit
/// dunklem Symbol; darunter der Name in 11 auf 75 %. Breite 68.
///
/// Mein erster Mac-Knopf trug nur ein Symbol in einem Umriss und hieß für
/// niemanden etwas — die Beschriftung stand allein für VoiceOver da.
struct Detailaktion: View {
    let symbol: String
    let titel: LocalizedStringKey
    var aktiv = false
    let auswahl: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: auswahl) {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(aktiv ? Stil.grund : Stil.schrift)
                    .frame(width: 44, height: 44)
                    .background(aktiv ? Stil.akzent
                                      : Stil.schrift.opacity(schwebt ? 0.16 : 0.09),
                                in: Circle())
                Text(titel)
                    .font(.system(size: 11))
                    .foregroundStyle(Stil.schrift.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(width: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
        .accessibilityLabel(Text(titel))
        .accessibilityAddTraits(aktiv ? [.isButton, .isSelected] : .isButton)
    }
}

/// Der Kopf einer Detailseite: Pfeil links, Titel daneben.
///
/// **Kein Umriss, kein Kreis** — ein blanker Winkel in 20 semibold auf 40 × 40,
/// wie `Detailkopf` in `Sources/Shared/Stil.swift`. Der Titel blendet ein,
/// wenn weit genug gescrollt ist.
///
/// **Keine Glasleiste dahinter.** Auf dem iPhone trägt sie den Titel über dem
/// scrollenden Bild. Hier reicht die Kulisse nur über die rechten zwei
/// Drittel, also stand die Leiste links auf blankem Grund und war als
/// dunkler Balken zu sehen — rechts, wo das Bild liegt, verlor sie sich
/// darin. Ein Streifen, der nur halb da ist, ist schlimmer als keiner.
/// Wo die Seite gerade steht.
///
/// **Warum das ein eigenes Objekt ist und kein `@State` in der Seite.**
///
/// `onScrollGeometryChange` feuert bei jedem Takt des Scrollens. Schreibt es
/// in ein `@State` der Seite, wertet SwiftUI deren **ganzen Rumpf** neu aus —
/// bei einer Serienseite also Kopf, Reiterreihe und die Folgenliste, und das
/// sechzigmal in der Sekunde. Beim schnellen Ziehen kommt der Hauptlauf dann
/// nicht mehr nach, die Scrollfläche verliert den Anschluss und springt.
///
/// Als `@Observable` wird nur neu gezeichnet, wer den Wert **liest** — und
/// das ist einzig der `Detailkopf`. Die Seite gibt den Halter nur weiter.
@MainActor
@Observable
final class Kopfstand {
    var versatz: CGFloat = 0
}

struct Detailkopf: View {
    let titel: String
    /// Wo die Seite steht — siehe `Kopfstand`.
    let stand: Kopfstand
    private var versatz: CGFloat { stand.versatz }

    /// **Ab wo die Leiste kommt — hergeleitet, nicht geschätzt.**
    ///
    /// Sie soll genau dann da sein, wenn der große Titel unter ihr
    /// verschwindet. Aus der Geometrie des Heldenkopfes:
    ///
    /// - Der Titel beginnt `Stil.titelHoehe + 98` unter der Oberkante des
    ///   Heldenbildes und ist 42 Punkt hoch.
    /// - Die Leiste selbst ist `Stil.titelHoehe + 24` hoch.
    ///
    /// Die Oberkante des Titels erreicht die Unterkante der Leiste also bei
    /// 98 − 24 = **74**, und 42 Punkt später ist er ganz darunter. Genau über
    /// diese Strecke blendet die Leiste ein.
    ///
    /// Vorher stand hier `Stil.heldHoehe - 150` = 230 — ein Wert aus der
    /// iPhone-Fassung, wo Heldenbild und Titel anders sitzen. Auf dem Mac kam
    /// die Leiste damit erst, wenn der Titel längst weg war.
    var ab: CGFloat = 98 - 24
    /// Über welche Strecke sie einblendet: die Höhe des großen Titels.
    var ueber: CGFloat = 42
    let zurueck: () -> Void

    private var staerke: Double {
        guard ueber > 0 else { return 1 }
        return Double(min(max((versatz - ab) / ueber, 0), 1))
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: zurueck) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Stil.schrift)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Zurück"))

            Text(verbatim: titel)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
                .opacity(staerke)

            Spacer(minLength: 0)
        }
        // **Bündig mit dem Inhalt.** Die Fensterampel sitzt über der
        // Seitenleiste, nicht über dem Inhaltsbereich — der Abstand, den ich
        // hier freigehalten hatte, war nie nötig. Der Pfeil steht jetzt auf
        // derselben Linie wie „Weiterschauen" auf der Startseite; die 8 Punkt
        // Ausgleich sind der Innenabstand des Knopfes selbst.
        .padding(.leading, Stil.randAbstand - 8)
        .padding(.trailing, Stil.randAbstand)
        // Seit der Inhalt unter der Titelleiste durchläuft, sitzt der Pfeil
        // sonst auf der Fensterkante. 24 setzt ihn auf dieselbe Höhe wie die
        // Seitenleiste ihre Wortmarke.
        .padding(.top, 24)
        // **Luft unter dem Text.** Die Leiste reicht ein Stück tiefer als
        // ihr Inhalt; sonst klebt der Titel auf der Haarlinie. Der Betrag
        // steht zweimal: einmal als Abstand, damit der Text an seinem Platz
        // bleibt, und einmal in der Höhe, damit die Leiste nach unten wächst
        // statt den Text mitzunehmen.
        .padding(.bottom, 10)
        .frame(height: Stil.titelHoehe + 24 + 10, alignment: .bottom)
        // **Die Leiste, die beim Scrollen kommt** — wörtlich wie auf iPhone
        // und iPad: unten eine Haarlinie, dahinter Glas, und solange das Bild
        // oben steht stattdessen ein weicher Verlauf, damit der Pfeil auf
        // hellem Bild lesbar bleibt.
        //
        // Nicht zu verwechseln mit dem milchigen Streifen, den macOS 26
        // ungefragt über jede Scrollfläche legt — der ist weiterhin
        // abgestellt (`ohneKanteneffekt`). Diese hier ist gewollt.
        .background(alignment: .bottom) {
            Rectangle().fill(Stil.linie).frame(height: 1).opacity(staerke)
        }
        .background {
            ZStack {
                LinearGradient(colors: [Stil.grund.opacity(0.7), Stil.grund.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .opacity(1 - staerke)
                // **Nur wenn sie etwas tut.**
                //
                // `Leistenglas` ist eine *lebende* Unschärfe: sie verwischt,
                // was darunter durchläuft, und rechnet das bei jedem Bild neu
                // — auch dann, wenn die Maske sie auf null stellt und man
                // nichts sieht. Über einer scrollenden Seite ist das die
                // teuerste Fläche im Fenster, und sie stand dort dauerhaft.
                //
                // Steht sie erst ab einem Hauch Sichtbarkeit in der Ansicht,
                // kostet das Scrollen im Heldenbild gar nichts.
                if staerke > 0.01 {
                    Leistenglas(staerke: staerke)
                }
            }
            .ignoresSafeArea(edges: .top)
        }
    }
}

/// Eine waagerechte Reihe mit Pfeilen zum Durchblättern.
///
/// **Nur auf dem Mac.** Auf iPhone und Fernseher wischt oder drückt man; hier
/// gibt es Zeiger und womöglich kein Trackpad, und dann ist eine waagerechte
/// Reihe ohne Pfeile nicht erreichbar. Der Grund ist die Eingabeart — genau
/// die Sorte Abweichung, die Abschnitt F erlaubt.
///
/// Die Pfeile erscheinen beim Schweben und nur dort, wo es etwas zu holen
/// gibt: am linken Rand keiner nach links, am rechten keiner nach rechts.
struct Blätterreihe<Inhalt: View>: View {
    /// Der seitliche Rand. **Null, wenn der Aufrufer schon einen setzt** —
    /// sonst stehen die Kacheln 48 Punkt eingerückt unter einer Überschrift,
    /// die bei 24 beginnt, und die Linie stimmt nicht mehr.
    var rand: CGFloat = Stil.randAbstand
    var schrittweite: CGFloat = 3
    var breiteJeStueck: CGFloat = Stil.kachelBreite + Stil.kachelAbstand
    /// Wie hoch das **Bild** einer Kachel ist — nicht die ganze Kachel.
    ///
    /// Die Blätterpfeile gehören optisch in die Mitte des Bildes. Mittig über
    /// der ganzen Reihe sitzen sie zu tief, weil unter jedem Bild noch zwei
    /// Textzeilen stehen; bei einem Poster sind das rund 45 Punkt Versatz,
    /// und die sieht man.
    var bildHoehe: CGFloat = Stil.kachelHoehe
    @ViewBuilder let inhalt: Inhalt

    @State private var schwebt = false
    @State private var versatz: CGFloat = 0
    @State private var gesamt: CGFloat = 0
    @State private var sichtbar: CGFloat = 0

    /// Was ein Takt über die Reihe verrät — in einem Wert, damit ein
    /// Beobachter genügt.
    private struct Messwerte: Equatable {
        let versatz: CGFloat
        let gesamt: CGFloat
        let sichtbar: CGFloat
    }

    private var kannLinks: Bool { versatz > 1 }
    private var kannRechts: Bool { versatz + sichtbar < gesamt - 1 }

    var body: some View {
        ScrollView(.horizontal) {
            // **`LazyHStack`, nicht `HStack`.** Ein `HStack` baut jede Kachel
            // sofort — die Besetzungsreihe elf Bilder, die Ähnliches-Reihe
            // ebenso viele —, und zwar in demselben Bild, in dem die Seite
            // hereinfährt. Das war das Ruckeln: nicht die Bewegung war hart,
            // sondern sie verlor Bilder, weil daneben die halbe Seite gebaut
            // wurde. Beim Hinausfahren stand alles längst, deshalb lief es
            // dort weich.
            LazyHStack(alignment: .top, spacing: Stil.kachelAbstand) { inhalt }
                .padding(.horizontal, rand)
                // Damit die Kacheln beim Schweben oben nicht abgeschnitten
                // werden, wenn sie sich vergrößern.
                .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
        .ohneKanteneffekt()
        .scrollPosition($stelle, anchor: .leading)
        // **Ein Beobachter statt zweier Geometrieleser.** Die beiden
        // `GeometryReader` schrieben beim Auslegen in den Zustand und lösten
        // damit weitere Auslegevorgänge aus — auch das kostete Bilder.
        .onScrollGeometryChange(for: Messwerte.self) {
            Messwerte(versatz: $0.contentOffset.x,
                      gesamt: $0.contentSize.width,
                      sichtbar: $0.containerSize.width)
        } action: { _, neu in
            versatz = neu.versatz
            gesamt = neu.gesamt
            sichtbar = neu.sichtbar
        }
        // Oben ausgerichtet und von Hand gesetzt: die 4 Punkt sind der
        // senkrechte Rand der Reihe, 17 die halbe Knopfhöhe.
        .overlay(alignment: .topLeading) {
            if schwebt, kannLinks {
                pfeil("chevron.left", "Zurückblättern") { blättern(-1) }
                    .offset(y: 4 + bildHoehe / 2 - 17)
            }
        }
        .overlay(alignment: .topTrailing) {
            if schwebt, kannRechts {
                pfeil("chevron.right", "Weiterblättern") { blättern(1) }
                    .offset(y: 4 + bildHoehe / 2 - 17)
            }
        }
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
    }

    @State private var stelle: ScrollPosition = .init(idType: CGFloat.self)

    private func blättern(_ richtung: CGFloat) {
        let weite = breiteJeStueck * schrittweite
        let ziel = max(0, min(gesamt - sichtbar, versatz + richtung * weite))
        withAnimation(.easeInOut(duration: 0.28)) {
            stelle.scrollTo(x: ziel)
        }
    }

    private func pfeil(_ symbol: String, _ name: LocalizedStringKey,
                       _ auswahl: @escaping () -> Void) -> some View {
        Button(action: auswahl) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Stil.schrift)
                .frame(width: 34, height: 34)
                .background(Stil.grund.opacity(0.72), in: Circle())
                .overlay(Circle().strokeBorder(Stil.rand, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(name))
        .padding(.horizontal, 6)
        .transition(.opacity)
    }
}


/// Nimmt der Scrollfläche die milchige Leiste am Rand.
///
/// **Erst ab macOS 26**, und das Ziel steht auf 15 — deshalb die Prüfung.
/// Auf älteren Fassungen gibt es den Effekt gar nicht, dort ist nichts zu
/// tun.
extension View {
    @ViewBuilder
    func ohneKanteneffekt() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
    }
}


// MARK: - Übernahme

/// „Läuft auf dem iPhone — hier weiterschauen", in der Form der Seitenleiste.
///
/// **`Mac`-eigene Fassung, weil die Leiste schmal ist.** Auf dem Fernseher
/// trägt das Abzeichen zwei Zeilen nebeneinander, hier stehen sie
/// untereinander und der Titel darf umbrechen. Gleicher Zweck, andere Breite
/// — die Benennung (`titelzeile`, `geraetezeichen`) teilen sich beide.
struct Uebernahmezeile: View {
    let sitzung: Fremdsitzung
    @State private var schwebt = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: sitzung.geraetezeichen)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Stil.akzent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Hier weiterschauen")
                    .font(Stil.kachelTitel)
                    .foregroundStyle(Stil.schrift)
                    .lineLimit(1)
                Text(verbatim: sitzung.titelzeile)
                    .font(.system(size: 11))
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(schwebt ? Stil.akzent.opacity(0.12) : Stil.akzent.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: Stil.ecke))
        .overlay(RoundedRectangle(cornerRadius: Stil.ecke)
            .strokeBorder(Stil.akzent.opacity(schwebt ? 0.35 : 0.18)))
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
    }
}
