import JellyfinKit
import SwiftUI

/// Die Nachfrage vor jedem Download — **H3, H5, H6.**
///
/// Bei Netflix drückt man auf Laden und es passiert einfach etwas: 300 MB, in
/// zwei Minuten fertig. Bei uns können es 18,6 GB sein, weil wir nie
/// transkodieren und deshalb die Originaldatei laden. Drei Zahlen und ein
/// Knopf sind bei dieser Größe das Mindeste — und der Satz darunter erklärt
/// die Zahl, statt sich für sie zu entschuldigen: **es ist der Vorzug, für
/// den es die App gibt**, kein Mangel.
///
/// Drei Lagen, und welche gilt, entscheidet nicht die Ansicht:
/// `Downloadregeln.platz` und `.darfLaden` sagen es, und beide sind im Paket
/// nachgerechnet.
struct Ladeblatt: View {
    @Binding var offen: Bool
    let model: AppModel
    /// Was geladen werden soll. Bei einer Staffel mehrere.
    let posten: [Downloadposten]
    /// Für den Titel: „Dune: Part Two" oder „Staffel 2".
    let titel: String
    /// Kennung → Bildadresse. Wandert mit auf die Platte, sonst steht die
    /// Liste im Flugzeug ohne Bilder da. Bei einer Serie gehören beide
    /// hinein: das Plakat der Serie und das Querbild jeder Folge.
    var bilder: [String: URL] = [:]
    /// Was hinterher gezeigt werden soll, etwa eine Meldung.
    var danach: () -> Void = {}
    /// Wenn der Download gleich nach dem Start scheitert — für den
    /// Hinweisstreifen der Seite darunter.
    var gescheitert: (String) -> Void = { _ in }
    /// **Die Qualität wird hier gewählt** — beim Film, der keine Auswahl
    /// davor hat. Eine Serie kommt aus `Ladeauswahl` und bringt ihre Wahl
    /// schon mit; dann steht sie hier nur da.
    var qualitaetWaehlen = false

    @State private var wahl: Downloadqualitaet = .original

    private var verwaltung: Downloadverwaltung { model.downloads }
    /// Die Posten in der gewählten Qualität — mit geschätzter Größe, sobald
    /// umgewandelt wird.
    private var fassung: [Downloadposten] {
        qualitaetWaehlen ? posten.map { $0.inQualitaet(wahl) } : posten
    }
    private var bytes: Int64 { fassung.reduce(0) { $0 + $1.bytes } }
    private var umgewandelt: Bool { fassung.contains(where: \.umgewandelt) }
    private var angeboten: [Downloadqualitaet] {
        Downloadqualitaet.angeboten(
            waehlbar: model.downloadqualitaetWaehlbar,
            quellBitrate: Downloadqualitaet.quellBitrate(posten.map { ($0.bytes, $0.laufzeitTicks) }))
    }
    /// Größe als Text — mit „≈", wenn sie geschätzt ist.
    private var groessentext: String {
        (umgewandelt ? "≈ " : "") + Downloadregeln.groesse(bytes)
    }
    private var auskunft: Downloadregeln.Platzauskunft { verwaltung.auskunft(fuer: bytes) }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .blatt(offen: $offen) {
                if !auskunft.reicht {
                    platzknapp
                } else if !Downloadregeln.darfLaden(imWLAN: verwaltung.imWLAN,
                                                   nurUeberWLAN: verwaltung.nurUeberWLAN) {
                    ohneWLAN
                } else {
                    normalfall
                }
            }
    }

    // MARK: Die drei Lagen

    private var normalfall: some View {
        VStack(spacing: 0) {
            Blattrubrik(text: Text(verbatim: String(localized: "\(titel) laden")))
            angabe("internaldrive", "Größe", groessentext)
            if qualitaetWaehlen, model.downloadqualitaetWaehlbar, angeboten.count > 1 {
                qualitaetszeile
            } else if let g = guete {
                angabe("sparkles", "Qualität", g)
            }
            angabe("externaldrive", "Danach frei", Downloadregeln.groesse(auskunft.freiDanach))
            knopf("Laden", gefuellt: true) { starten() }
            // **Erklärt die Zahl, statt sich zu entschuldigen.**
            if umgewandelt {
                hinweis("Der Server wandelt die Datei beim Laden um. Die Größe ist geschätzt, Untertitel kommen als eigene Dateien mit.")
            } else {
                hinweis("Swiftly lädt die Originaldatei, in derselben Qualität wie beim Streamen.")
            }
        }
    }

    private var ohneWLAN: some View {
        VStack(spacing: 0) {
            Blattrubrik(text: Text(verbatim: String(localized: "\(titel) laden")))
            angabe("internaldrive", "Größe", groessentext)
            angabe("wifi.slash", "Kein WLAN", String(localized: "Mobilfunk"), warnend: true)
            // Der obere Knopf ist die freundliche Antwort und steht deshalb
            // oben und gefüllt. Der untere ist möglich, aber man muss ihn
            // lesen.
            knopf("In die Warteschlange", gefuellt: true) { starten() }
            knopf("Jetzt über Mobilfunk laden", gefuellt: false) {
                model.nurUeberWLAN = false
                starten()
            }
            hinweis("Der Download startet von selbst, sobald WLAN da ist.")
        }
    }

    private var platzknapp: some View {
        VStack(spacing: 0) {
            Blattrubrik(text: Text("Nicht genug Platz"))
            angabe("internaldrive", "Diese Datei", groessentext)
            // **Der naheliegende Ausweg ist eine kleinere Fassung.** Beim Film
            // steht die Wahl deshalb auch hier; reicht es danach, wechselt
            // das Blatt von selbst in den Normalfall.
            if qualitaetWaehlen, model.downloadqualitaetWaehlbar, angeboten.count > 1 {
                qualitaetszeile
            }
            angabe("externaldrive", "Frei auf dem Gerät",
                   Downloadregeln.groesse(verwaltung.frei), warnend: true)

            // **Ein Ausweg statt einer Fehlermeldung.** Die App weiss, was
            // gesehen und damit entbehrlich ist, und rechnet vor, dass es
            // reicht. H6: sie löscht deswegen trotzdem nichts von selbst.
            if auskunft.reichtNachAufraeumen, !auskunft.entbehrlich.isEmpty {
                angabe("checkmark.circle", "Gesehene Titel",
                       Downloadregeln.groesse(auskunft.entbehrlichBytes))
                knopf("Gesehene entfernen und laden", gefuellt: true) {
                    verwaltung.entfernen(auskunft.entbehrlich.map(\.id))
                    starten()
                }
                knopf("Abbrechen", gefuellt: false) { offen = false }
            } else {
                hinweis("Auch nach dem Entfernen der gesehenen Titel reicht der Platz nicht. In den Einstellungen unter Offline steht, was belegt ist.")
                knopf("Verstanden", gefuellt: false) { offen = false }
            }
        }
    }

    // MARK: Bausteine

    private func angabe(_ symbol: String, _ was: LocalizedStringKey,
                        _ wert: String, warnend: Bool = false) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(warnend ? Stil.warnung : Stil.schriftLeise)
                .frame(width: 20)
            Text(was)
                // **Mitwachsend, nicht fest** — BRAND.md, Abschnitt 2. Der Wert
                // rechts bleibt fest: er läuft tabellarisch und steht mit den
                // anderen Zeilen in einer Spalte.
                .mitwachsend(15)
                .foregroundStyle(warnend ? Stil.warnung : Stil.schrift)
            Spacer(minLength: 12)
            Text(verbatim: wert)
                .font(.system(size: 15))
                .monospacedDigit()
                .foregroundStyle(Stil.schrift)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, Stil.randAbstand)
        // **52 wie jede Zeile in einem Blatt.** Sie hatte als einzige gar
        // kein Mass und stand allein auf ihrem Innenabstand — gut 44 Punkt,
        // also acht flacher als die Zeilen im Blatt nebenan. `minHeight`,
        // damit sie mit groesserer Systemschrift wachsen darf.
        .frame(minHeight: 52)
        .overlay(alignment: .top) {
            // Blatt, also durchgehend — siehe `Blattlinie`.
            Blattlinie()
        }
    }

    /// **Die Qualität als Zeile mit Wahl rechts** — dieselbe Plakette wie
    /// in der Ladeauswahl, damit Film und Serie dieselbe Stelle haben.
    private var qualitaetszeile: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 17))
                .foregroundStyle(Stil.schriftLeise)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text("Qualität")
                .mitwachsend(15)
                .foregroundStyle(Stil.schrift)
            Spacer(minLength: 12)
            Qualitaetsplakette(wahl: $wahl, angeboten: angeboten, waehlbar: true,
                               groesse: { q in posten.reduce(0) {
                                   $0 + q.geschaetzteBytes(original: $1.bytes,
                                                           laufzeitTicks: $1.laufzeitTicks) } })
        }
        .padding(.vertical, 4)
        .padding(.horizontal, Stil.randAbstand)
        .frame(minHeight: 52)
        .overlay(alignment: .top) { Blattlinie() }
    }

    private func knopf(_ text: LocalizedStringKey, gefuellt: Bool,
                       tun: @escaping () -> Void) -> some View {
        Button(action: tun) { Text(text) }
            .buttonStyle(gefuellt ? AnyButtonStyle(HauptknopfStil(dehnt: true))
                                  : AnyButtonStyle(NebenknopfStil(dehnt: true)))
            .padding(.horizontal, Stil.randAbstand)
            .padding(.top, 14)
    }

    private func hinweis(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .mitwachsend(13)
            .foregroundStyle(Stil.schriftLeise)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Stil.randAbstand)
            .padding(.top, 10)
    }

    /// Woraus die Qualitätszeile besteht — die Angaben, die den Preis
    /// begründen. Fehlen sie, fällt die Zeile weg statt „unbekannt" zu sagen.
    private var guete: String? {
        var teile: [String] = []
        // Kommt die Serie umgewandelt aus der Auswahl, steht die Stufe vorn.
        if let q = fassung.first?.guete, !q.istOriginal { teile.append(q.name + " · " + q.zusatz()) }
        if let c = fassung.first?.container { teile.append(c.uppercased()) }
        return teile.isEmpty ? nil : teile.joined(separator: " · ")
    }

    private func starten() {
        offen = false
        // Nur was neu dazukommt — ein schon gescheiterter Posten mit
        // derselben Kennung waere sonst sofort „gescheitert".
        let neu = fassung.map(\.id).filter { id in !verwaltung.posten.contains { $0.id == id } }
        verwaltung.anstossen(fassung, bilder: bilder)
        danach()
        let lager = verwaltung, melden = gescheitert
        Task {
            if let grund = await lager.sofortGescheitert(neu) { melden(grund) }
        }
    }
}

/// Zwei Knopfstile in einem Ausdruck — ohne das wird aus dem `if` im
/// `buttonStyle` ein Typfehler.
struct AnyButtonStyle: ButtonStyle {
    private let bauen: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ stil: S) {
        bauen = { AnyView(stil.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { bauen(configuration) }
}
