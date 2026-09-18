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

    private var verwaltung: Downloadverwaltung { model.downloads }
    private var bytes: Int64 { posten.reduce(0) { $0 + $1.bytes } }
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
            angabe("internaldrive", "Größe", Downloadregeln.groesse(bytes))
            if let g = guete { angabe("sparkles", "Qualität", g) }
            angabe("externaldrive", "Danach frei", Downloadregeln.groesse(auskunft.freiDanach))
            knopf("Laden", gefuellt: true) { starten() }
            // **Erklärt die Zahl, statt sich zu entschuldigen.**
            hinweis("Swiftly lädt die Originaldatei — dieselbe Qualität wie beim Streamen, weil nie umgerechnet wird.")
        }
    }

    private var ohneWLAN: some View {
        VStack(spacing: 0) {
            Blattrubrik(text: Text(verbatim: String(localized: "\(titel) laden")))
            angabe("internaldrive", "Größe", Downloadregeln.groesse(bytes))
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
            angabe("internaldrive", "Diese Datei", Downloadregeln.groesse(bytes))
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
                .font(.system(size: 16))
                .foregroundStyle(warnend ? Stil.warnung : Stil.schrift)
            Spacer(minLength: 12)
            Text(verbatim: wert)
                .font(.system(size: 16))
                .monospacedDigit()
                .foregroundStyle(Stil.schrift)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, Stil.randAbstand)
        .overlay(alignment: .top) {
            Trennlinie().padding(.leading, Stil.randAbstand)
        }
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
            .font(.system(size: 13))
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
        if let c = posten.first?.container { teile.append(c.uppercased()) }
        return teile.isEmpty ? nil : teile.joined(separator: " · ")
    }

    private func starten() {
        offen = false
        verwaltung.anstossen(posten, bilder: bilder)
        danach()
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
