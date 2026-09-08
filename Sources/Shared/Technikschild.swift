import JellyfinKit
import SwiftUI

/// Das Technikschild über dem laufenden Bild — **die Auskunft, die einen
/// Fehlerbericht brauchbar macht.**
///
/// **Warum es ein Schild ist und kein Reiter.** Vorher standen dieselben
/// Zahlen als Reiter „Technik" im Wiedergabeblatt. Das ist die falsche Form
/// für die Frage, die sie beantworten: „läuft es gerade rund?" ist keine
/// Frage, die man einmal stellt, sondern eine, der man beim Laufen zusieht.
/// Ein Blatt verdeckt das Bild und geht wieder zu; man liest eine Zahl,
/// schliesst, sieht wieder Ruckeln und weiss nicht, ob die Zahl dazu gehörte.
/// Streamyfin loest es als bleibendes Schild, und aus demselben Grund.
///
/// **Es nimmt keine Eingaben.** `allowsHitTesting(false)` steht an der
/// Aufrufstelle, nicht hier — das Schild ist eine Auskunft, kein Bedienteil,
/// und es darf der Steuerung darunter nichts wegnehmen. Auf dem Fernseher
/// gilt dasselbe für den Fokus.
///
/// **Oben links, und zwar immer.** Unten liegen überall die Steuerung und der
/// Regler, rechts oben auf iPhone und iPad der Schliessen-Knopf. Oben links
/// ist die einzige Ecke, die in allen vier Playern frei ist — und ein Schild,
/// das je nach Gerät woanders sitzt, muss man suchen.
struct Technikschild: View {
    /// Was der Server ausliefert und warum — die wichtigste Zeile.
    let plan: PlaybackPlan
    /// Was VLC beim Laufen zählt. `nil`, solange nichts gemessen ist.
    let werte: Spielwerte?
    /// Wie gross das Schild insgesamt ausfällt. Der Fernseher wird aus drei
    /// Metern gelesen, das iPhone aus dreissig Zentimetern.
    var fern = false

    private var quelle: MediaSource? { plan.quelle }
    private var video: MediaStream? { quelle.flatMap(Dateiangaben.videospur) }
    private var ton: MediaStream? { quelle.flatMap(Dateiangaben.tonspuren)?.first }
    private var untertitel: MediaStream? {
        quelle.flatMap(Dateiangaben.untertitelspuren)?.first
    }

    private var grad: CGFloat { fern ? 22 : 12 }
    private var abstand: CGFloat { fern ? 7 : 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: abstand) {
            kopfzeile

            // Der Grund steht direkt unter dem Wort, nicht am Ende: wer
            // „Transkodiert" liest, will als Nächstes wissen, woran es lag.
            if plan.method == .transcode, let grund = plan.reasons.first {
                zeile(grund.text, farbe: Stil.warnung)
            }

            if let bild = Technikangaben.bildzeile(
                breite: video?.width, hoehe: video?.height,
                // Farbtiefe liefert der Server in unserem Modell nicht mit;
                // der Umfang schon, und der ist die Angabe, an der auf dem
                // Fernseher der HDR-Schalter haengt.
                tiefe: nil,
                umfang: video?.videoRangeType?.rawValue) {
                zeile(bild)
            }
            if let v = videozeile { zeile(v) }
            if let t = tonzeile { zeile(t) }
            if let u = untertitelzeile { zeile(u) }
            if let d = dateizeile { zeile(d) }

            if let werte {
                // **Eine Haarlinie, kein Abstand.** Was darüber steht,
                // beschreibt die Datei und ändert sich nie; was darunter
                // steht, zählt beim Laufen hoch. Zwei Sorten Zahl, und man
                // soll sie beim Überfliegen auseinanderhalten.
                Rectangle().fill(Stil.rand)
                    .frame(width: fern ? 260 : 150, height: 1)
                    .padding(.vertical, abstand / 2)

                zeile("\(String(localized: "Eingang")) \(werte.eingang)")
                zeile("\(String(localized: "Demuxer")) \(werte.demuxer)")
                verlustzeile(werte)
            }
        }
        .font(.system(size: grad, weight: .medium, design: .monospaced))
        .foregroundStyle(Stil.schrift)
        .padding(.horizontal, fern ? 20 : 12)
        .padding(.vertical, fern ? 16 : 10)
        .background {
            // Deckend, nicht durchscheinend: das Schild liegt über bewegtem
            // Bild, und über bewegtem Bild ist jede Transparenz mal lesbar
            // und mal nicht. Dieselbe Entscheidung wie bei den Leisten.
            RoundedRectangle(cornerRadius: fern ? 14 : Stil.ecke)
                .fill(Stil.grund.opacity(0.82))
        }
        .overlay {
            RoundedRectangle(cornerRadius: fern ? 14 : Stil.ecke)
                .strokeBorder(Stil.rand)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Zeilen

    /// Die Auslieferungsart, und sie ist die einzige farbige Zeile.
    ///
    /// Direct Play und Direct Stream stehen gleich da — beide sind
    /// verlustfrei, und die Unterscheidung interessiert nur, wer sie sucht.
    /// Nur die Umrechnung faellt auf, weil sie das eine ist, was diese App zu
    /// vermeiden verspricht.
    private var kopfzeile: some View {
        Text(verbatim: Technikangaben.auslieferung(plan.method))
            .font(.system(size: grad + 2, weight: .bold, design: .monospaced))
            .foregroundStyle(Technikangaben.gewicht(plan.method) == .gut
                             ? Stil.akzent : Stil.warnung)
    }

    private var videozeile: String? {
        guard let name = Technikangaben.codecname(video?.codec) else { return nil }
        var text = "\(String(localized: "Bild")) \(name)"
        if let rate = Technikangaben.bildrate(video?.bildrate) { text += " · \(rate) fps" }
        return text
    }

    private var tonzeile: String? {
        guard let name = Technikangaben.codecname(ton?.codec) else { return nil }
        var text = "\(String(localized: "Ton")) \(name)"
        if let k = Technikangaben.kanalwort(ton?.channels) { text += " · \(k)" }
        if let sprache = ton?.language, !sprache.isEmpty { text += " · \(sprache)" }
        return text
    }

    private var untertitelzeile: String? {
        guard let name = Technikangaben.codecname(untertitel?.codec) else { return nil }
        var text = "\(String(localized: "Untertitel")) \(name)"
        if let sprache = untertitel?.language, !sprache.isEmpty { text += " · \(sprache)" }
        return text
    }

    /// Container und Grösse — was auf der Platte liegt.
    private var dateizeile: String? {
        guard let quelle else { return nil }
        var teile: [String] = []
        if let c = Dateiangaben.container(quelle) { teile.append(c.uppercased()) }
        teile.append(Dateiangaben.groesse(quelle))
        return teile.isEmpty ? nil : "\(String(localized: "Datei")) \(teile.joined(separator: " · "))"
    }

    /// **Die Zeile, wegen der es das Schild gibt.**
    ///
    /// Verworfene und zu späte Bilder sind der Unterschied zwischen „läuft"
    /// und „läuft gerade noch": ein Bild, das stockt, und eines, das still
    /// Einzelbilder wegwirft, sehen aus drei Metern gleich aus. Steht hier
    /// eine Null, war es das Netz oder der Server; steht hier eine Zahl, war
    /// es der Dekoder.
    private func verlustzeile(_ w: Spielwerte) -> some View {
        let schlecht = w.verworfen > 0 || w.zuSpaet > 0 || w.tonVerloren > 0
        return Text(verbatim: "\(String(localized: "Verworfen")) \(w.verworfen)"
                    + " · \(String(localized: "zu spät")) \(w.zuSpaet)"
                    + " · \(String(localized: "Ton weg")) \(w.tonVerloren)")
            .foregroundStyle(schlecht ? Stil.warnung : Stil.schriftLeise)
    }

    private func zeile(_ text: String, farbe: Color = Stil.schriftLeise) -> some View {
        Text(verbatim: text).foregroundStyle(farbe)
    }
}
