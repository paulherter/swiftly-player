import JellyfinKit
import SwiftUI
import VLCKit

/// Einstellungen während der Wiedergabe.
///
/// Vollständig eigene Bausteine: kein `List`, kein `Toggle`, kein `Picker`,
/// kein Blattgriff. Apples Fassungen bringen jeweils ihr eigenes
/// Erscheinungsbild mit, das neben unserer flachen Gestaltung auffällt.
///
/// Flache Liste statt verschachtelter Ebenen: Untertitel und Ton greift man
/// mitten im Film, die sollen nicht hinter zwei Ebenen liegen.
struct PlayerSettingsSheet: View {
    let surface: VLCPlayerView?
    @Binding var offen: Bool
    @Binding var tempo: Float
    @Binding var schlafminuten: Int?
    @Binding var querformatFest: Bool

    /// Erzwingt ein Neuzeichnen, wenn VLC die Spurwahl übernommen hat.
    @State private var stand = 0

    /// Die eigene Wahl, unabhängig von VLC.
    ///
    /// VLC übernimmt eine Spurwahl nicht sofort — liest man direkt danach
    /// `isSelected`, steht dort noch der alte Stand. Die Anzeige hing dadurch
    /// einen Klick hinterher, und beim Wechsel von „Aus" auf eine Spur trugen
    /// kurz **beide** einen Haken. Was angetippt wurde, wissen wir aber selbst.
    @State private var tonWahl: String?
    @State private var untertitelWahl: String??
    @Environment(\.verticalSizeClass) private var hoehenklasse

    // Stufen und Beschriftung liegen in JellyfinKit — sie standen dreimal
    // da, einmal je Plattform.
    private let tempi = Tempostufen.werte
    private let schlafzeiten = Schlafzeiten.werte

    @State private var breite: CGFloat = 0

    /// Auch dieser Kopf sitzt oben links, und auch er liegt im Fenster
    /// unter der Ampel. Er steht im Player und erbt dessen Lage.
    /// Selbst gerechnet und nicht aus der Umgebung gelesen: der Player ist
    /// ein `fullScreenCover` und haengt ausserhalb der Ansicht, die den Wert
    /// setzt. Ob die Umgebung dorthin durchreicht, will ich nicht annehmen —
    /// angenommen hatte ich hier schon zweimal genug.
    private var imFenster: Bool {
        Fensterknoepfe.imFenster(fensterbreite: breite)
    }

    /// Drei Spalten nebeneinander, wenn Breite da ist — sonst eine.
    ///
    /// **Nicht allein an der Höhenklasse.** Auf dem iPhone ist die im
    /// Querformat `compact`, und das war die richtige Frage, solange es nur
    /// iPhones gab. Ein iPad meldet auch quer `regular`; der Dialog stand
    /// dort deshalb einspaltig auf 1180 Punkt Breite. Gemessen wird jetzt,
    /// was zählt: der Platz.
    private var quer: Bool { hoehenklasse == .compact || breite >= 900 }

    var body: some View {
        ZStack(alignment: .top) {
            // Der ganze Schirm statt einer schwebenden Tafel. Die schnitt oben
            // und unten an und stand quer im Bild; Netflix und Paramount+
            // nehmen im Querformat ebenfalls die volle Fläche und stellen die
            // Auswahl in Spalten. Das Bild bleibt dahinter sichtbar.
            // Fast deckend: bei 0,9 schienen die Knöpfe des Players durch und
            // lagen quer über der Auswahl.
            Stil.grund.opacity(0.97)
                .ignoresSafeArea()
                .onTapGesture { offen = false }

            // Ohne Spacer: sonst bekommen die Spalten nur ihre Wunschhöhe und
            // die unterste Gruppe wurde am Bildrand abgeschnitten, statt zu
            // scrollen.
            // **Der Inhalt haengt an `offen`, die Flaeche nicht.**
            //
            // Das Blatt bleibt montiert und blendet nur, damit es beim
            // Schliessen nicht schlagartig verschwindet (siehe `PlayerScreen`).
            // Sein Inhalt darf das nicht mitmachen: `untertitel` und `ton`
            // lesen `surface?.untertitelspuren` und `?.tonspuren`, und die
            // gehen direkt in VLCKit. Dauerhaft montiert waeren das bei jedem
            // 500-ms-Takt vier Anfragen, in jeder Wiedergabe, auch wenn
            // niemand den Dialog offen hat.
            //
            // Sichtbar kostet es fast nichts: beim Schliessen geht die helle
            // Schrift einen Moment vor der Flaeche. Gemessen wird der Schirm
            // dadurch kurz *dunkler* (0,168 → 0,109), nicht heller — auf
            // dunklem Grund ist das nicht zu sehen. Der helle Blitz, um den es
            // ging, war ein Sprung auf 0,918.
            if offen {
                VStack(spacing: 0) {
                    kopf
                    if quer { spalten } else { einzelspalte }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { neu in
            breite = neu
        }
    }

    /// Querformat: Untertitel, Ton und der Rest nebeneinander.
    private var spalten: some View {
        HStack(alignment: .top, spacing: 30) {
            ScrollView { untertitel }
            ScrollView { ton }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    geschwindigkeit
                    if bildWahlMoeglich { bild }
                    schlafzeit
                }
            }
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, 26)
        .padding(.bottom, 18)
    }

    /// Hochformat: eine Spalte, untereinander.
    private var einzelspalte: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                untertitel
                ton
                geschwindigkeit
                if bildWahlMoeglich { bild }
                schlafzeit
            }
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, 26)
    }

    private var kopf: some View {
        HStack {
            Text("Wiedergabe")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Stil.schrift)
            Spacer()
            Button { offen = false } label: {
                Text("Fertig")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Stil.akzent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Stil.randAbstand)
        .padding(.top, 18 + (imFenster ? Fensterknoepfe.hoehe : 0))
        .padding(.bottom, 16)
    }

    private var untertitel: some View {
        VStack(alignment: .leading, spacing: 0) {
            spaltentitel("Untertitel")
            Trennlinie()
            wahlzeile("Aus", gewaehlt: untertitelJetzt == nil) {
                untertitelWahl = .some(nil)
                surface?.waehleUntertitel(nil)
            }
            ForEach(surface?.untertitelspuren ?? [], id: \.trackId) { spur in
                Trennlinie()
                wahlzeile(spur.trackName, gewaehlt: untertitelJetzt == spur.trackName) {
                    untertitelWahl = .some(spur.trackName)
                    surface?.waehleUntertitel(spur)
                }
            }
        }
        .id(stand)
    }

    private var ton: some View {
        VStack(alignment: .leading, spacing: 0) {
            spaltentitel("Ton")
            Trennlinie()
            ForEach(Array((surface?.tonspuren ?? []).enumerated()), id: \.element.trackId) { paar in
                if paar.offset > 0 { Trennlinie() }
                wahlzeile(paar.element.trackName, gewaehlt: tonJetzt == paar.element.trackName) {
                    tonWahl = paar.element.trackName
                    surface?.waehleTonspur(paar.element)
                }
            }
        }
        .id(stand)
    }

    /// Die eigene Wahl hat Vorrang; erst wenn keine getroffen wurde, zählt
    /// das, was VLC meldet.
    private var untertitelJetzt: String? {
        if let untertitelWahl { return untertitelWahl }
        return surface?.gewaehlterUntertitel?.trackName
    }

    private var tonJetzt: String? {
        tonWahl ?? surface?.gewaehlteTonspur?.trackName
    }

    /// Kleiner gesperrter Titel über einer Spalte.
    private func spaltentitel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .textCase(.uppercase)
            .font(.system(size: 11, weight: .medium))
            .tracking(1.2)
            .foregroundStyle(Color.white.opacity(0.4))
            .padding(.bottom, 6)
    }

    /// Eine Auswahlzeile. Gewähltes im Akzent mit Haken.
    private func wahlzeile(_ text: String, gewaehlt: Bool,
                           aktion: @escaping () -> Void) -> some View {
        Button(action: aktion) {
            HStack(spacing: 10) {
                Text(text)
                    .font(.system(size: 15))
                    .foregroundStyle(gewaehlt ? Stil.akzent : Stil.schrift)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if gewaehlt {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Stil.akzent)
                }
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Auswahl als Chips — spart Höhe gegenüber einer Liste.
    private func chip(_ text: LocalizedStringKey, an: Bool, aktion: @escaping () -> Void) -> some View {
        Button(action: aktion) {
            Text(text)
                .font(.system(size: 13, weight: an ? .semibold : .regular))
                .foregroundStyle(an ? Stil.grund : Stil.schrift)
                .padding(.horizontal, 13)
                .frame(height: 30)
                .background(an ? Stil.akzent : Stil.erhoeht, in: Capsule())
                .overlay { Capsule().strokeBorder(an ? Stil.akzent : Stil.rand) }
        }
        .buttonStyle(.plain)
    }

    private var geschwindigkeit: some View {
        VStack(alignment: .leading, spacing: 10) {
            spaltentitel("Tempo")
            FlussReihe {
                ForEach(tempi, id: \.self) { wert in
                    chip(wert == 1 ? "1×" : LocalizedStringKey(beschriftung(wert)), an: tempo == wert) {
                        tempo = wert
                    }
                }
            }
        }
    }

    private var bild: some View {
        VStack(alignment: .leading, spacing: 10) {
            spaltentitel("Bild")
            FlussReihe {
                chip("Querformat fest", an: querformatFest) { querformatFest = true }
                chip("Frei drehbar", an: !querformatFest) { querformatFest = false }
            }
        }
    }

    /// Auf dem iPad gibt es die Wahl nicht: `Orientierung` ist dort ein
    /// Leerlauf, weil eine multitaskingfähige App die Drehung nicht erzwingen
    /// darf. In den Einstellungen ist die Zeile deshalb schon weg — hier
    /// stand sie noch, und zwar wirkungslos.
    private var bildWahlMoeglich: Bool { Orientierung.querformatSperreMoeglich }

    private var schlafzeit: some View {
        VStack(alignment: .leading, spacing: 10) {
            spaltentitel("Schlafzeit")
            FlussReihe {
                chip("Aus", an: schlafminuten == nil) { schlafminuten = nil }
                ForEach(schlafzeiten, id: \.self) { minuten in
                    chip("\(minuten)", an: schlafminuten == minuten) { schlafminuten = minuten }
                }
            }
        }
    }

    private func beschriftung(_ wert: Float) -> String {
        Tempostufen.beschriftung(wert)
    }
}
