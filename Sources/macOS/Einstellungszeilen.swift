import SwiftUI

/// Die Zeilen der Einstellungsseiten.
///
/// Aufbau wörtlich von der iPhone-Fassung: flache Zeilen mit Haarlinien,
/// Gruppen nur durch Leerraum und einen kleinen gesperrten Titel getrennt.
/// Keine Karten — die wären Netflix pur und stünden neben unseren flachen
/// Flächen fremd da.
///
/// Anders ist nur, was mit dem Zeiger zu tun hat: Zeilen sind 44 statt 52 hoch,
/// sie leuchten beim Schweben auf, und die Werteliste klappt an Ort und Stelle
/// auf statt als Blatt von unten.

/// Haarlinie, 1 Bildpunkt, Weiß 7 %.
struct Trennstrich: View {
    var body: some View { Rectangle().fill(Stil.linie).frame(height: 1) }
}

/// Gruppe mit gesperrtem Titel, Haarlinie oben und unten.
struct Einstellungsgruppe<Inhalt: View>: View {
    let titel: LocalizedStringKey
    @ViewBuilder let inhalt: Inhalt

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Kein `uppercased()`: aus einem Schlüssel lässt sich keine
            // Zeichenkette machen, ohne die Übersetzung zu verlieren.
            Text(titel)
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Stil.schrift.opacity(0.4))
                .padding(.top, 26)
                .padding(.bottom, 8)
            VStack(spacing: 0) { inhalt }
                .background(alignment: .top) { Trennstrich() }
                .background(alignment: .bottom) { Trennstrich() }
        }
    }
}

/// Gruppe ohne Titel — nur Haarlinien, wie auf der Profilseite.
struct Zeilengruppe<Inhalt: View>: View {
    @ViewBuilder let inhalt: Inhalt

    var body: some View {
        VStack(spacing: 0) { inhalt }
            .background(alignment: .top) { Trennstrich() }
            .background(alignment: .bottom) { Trennstrich() }
    }
}

/// Der Rumpf jeder Zeile: Symbol, Titel, Unterzeile, rechts etwas.
private struct Zeilenrumpf<Rechts: View>: View {
    let symbol: String
    let titel: Text
    var unter: Text?
    var akzent = false
    let schwebt: Bool
    @ViewBuilder let rechts: Rechts

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(akzent ? Stil.akzent : Stil.schriftLeise)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                titel
                    .font(.system(size: 15))
                    .foregroundStyle(akzent ? Stil.akzent : Stil.schrift)
                if let unter {
                    unter
                        .font(.system(size: 12))
                        .foregroundStyle(Stil.schrift.opacity(0.45))
                }
            }
            Spacer(minLength: 12)
            rechts
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(schwebt ? Stil.schrift.opacity(0.05) : .clear)
        .contentShape(Rectangle())
    }
}

/// Eine Zeile mit Schalter. Kein `Toggle` — der bringt Apples Kapselform,
/// Apples Grün und Apples Maße mit.
struct Schalterzeile: View {
    let symbol: String
    let titel: Text
    var unter: Text?
    @Binding var an: Bool

    @State private var schwebt = false

    var body: some View {
        Button { an.toggle() } label: {
            Zeilenrumpf(symbol: symbol, titel: titel, unter: unter, schwebt: schwebt) {
                Schalter(an: an)
            }
        }
        .buttonStyle(.plain)
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
        .accessibilityRepresentation { Toggle(isOn: $an) { titel } }
    }
}

/// Der Schalter selbst — Kapsel, Akzent wenn an.
struct Schalter: View {
    let an: Bool

    var body: some View {
        Capsule()
            .fill(an ? Stil.akzent : Stil.schrift.opacity(0.14))
            .frame(width: 38, height: 22)
            .overlay(alignment: an ? .trailing : .leading) {
                Circle()
                    .fill(an ? Stil.grund : Stil.schrift)
                    .frame(width: 16, height: 16)
                    .padding(3)
            }
            .animation(Stil.zeitUmschalten, value: an)
    }
}

// Eigene Steuerelemente sind für VoiceOver zunächst nur „Taste". Die
// folgenden Angaben sagen, worum es geht — dieselbe Sorgfalt, die die
// iPhone-Fassung an ihren Bausteinen trägt und die meinen bisher fehlte.

/// Eine Zeile, die rechts einen Wert zeigt und beim Anklicken etwas tut.
struct Wertezeile: View {
    let symbol: String
    let titel: Text
    var unter: Text?
    var wert: String?
    var akzent = false
    var pfeil = false
    var aktion: (() -> Void)?

    @State private var schwebt = false

    var body: some View {
        // Ohne eigene Aktion **kein** Knopf: die Zeile steht dann als
        // Beschriftung in einem `NavigationLink`, und ein Knopf darin würde
        // den Klick schlucken. Derselbe Fehler wie bei den Kacheln.
        Group {
            if let aktion {
                Button(action: aktion) { rumpf }.buttonStyle(.plain)
            } else {
                rumpf
            }
        }
        .onHover { schwebt = $0 && aktion != nil }
        .animation(Stil.zeitSchweben, value: schwebt)
    }

    private var rumpf: some View {
            Zeilenrumpf(symbol: symbol, titel: titel, unter: unter,
                        akzent: akzent, schwebt: schwebt) {
                HStack(spacing: 8) {
                    if let wert {
                        Text(verbatim: wert)
                            .font(.system(size: 14))
                            .foregroundStyle(Stil.schriftLeise)
                    }
                    if pfeil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Stil.schriftSehrLeise)
                    }
                }
            }
    }
}

/// Die Werteliste. Auf dem iPhone ein Blatt von unten; hier klappt sie
/// **unter der Zeile** auf — „Auswahl bleibt am Ort", dieselbe Regel wie bei
/// der Staffelpille und der Mehr-Liste.
struct Werteliste<E: Identifiable>: View {
    let eintraege: [E]
    let beschriftung: (E) -> String
    let istGewaehlt: (E) -> Bool
    let waehlen: (E) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(eintraege) { eintrag in
                Wertwahlzeile(text: beschriftung(eintrag),
                              gewaehlt: istGewaehlt(eintrag)) { waehlen(eintrag) }
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, 48)
        .background(Stil.flaeche)
        .overlay(alignment: .bottom) { Trennstrich() }
    }
}

private struct Wertwahlzeile: View {
    let text: String
    let gewaehlt: Bool
    let auswahl: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: auswahl) {
            HStack(spacing: 8) {
                Text(verbatim: text)
                    .font(Stil.koerper)
                    .foregroundStyle(gewaehlt ? Stil.akzent : Stil.schrift)
                Spacer(minLength: 0)
                if gewaehlt {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Stil.akzent)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Stil.zeileHoehe)
            .background(schwebt ? Stil.schrift.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { schwebt = $0 }
    }
}

/// Kopf einer Unterseite: Zurückpfeil und Titel nebeneinander.
///
/// Auf dem iPhone sind das zwei Dinge — ein Pfeil oben links und der Titel im
/// Inhalt. Im Fenster gibt es keinen Wisch zurück, also muss der Pfeil sichtbar
/// und treffbar sein; nebeneinander liest es sich als eine Zeile.
struct Unterseitenkopf: View {
    let titel: LocalizedStringKey
    let zurueck: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Aktionsknopf(symbol: "chevron.left", titel: "Zurück", auswahl: zurueck)
            Text(titel)
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(Stil.schrift)
            Spacer(minLength: 0)
        }
    }
}
