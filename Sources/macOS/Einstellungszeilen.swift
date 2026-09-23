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

/// **Eine Gruppe als eigene Flaeche.**
///
/// Sie trug ihre Zeilen randbuendig zwischen zwei Haarlinien — die aeltere
/// Bauart, aus der Zeit vor der Kartenoptik. Entschieden am 11.09.2026
/// gemeinsam mit iPhone und iPad: die Karte grenzt die Gruppe ohne Leerraum
/// ab und ist die Form, die man vom Geraet kennt.
///
/// **Sie ist die eine Ausnahme von „hoechstens eine gefuellte Flaeche je
/// Seite".** Eine Einstellungsseite hat keine Hauptsache und keinen weissen
/// Hauptknopf; die Regel schuetzt dessen Aussage, und wo keiner steht,
/// schuetzt sie nichts.
struct Karte<Inhalt: View>: View {
    @ViewBuilder let inhalt: Inhalt

    var body: some View {
        VStack(spacing: 0) { inhalt }
            // Karte = 14, nicht 16: 16 gehoert eigenen Flaechen und Tafeln,
            // 14 den Karten und Gruppen. Und `gruppenflaeche` statt
            // `flaeche`: ein grosser Block traegt denselben Ton heller als
            // ein Knopf — die Begruendung steht am Token.
            .background(Stil.gruppenflaeche,
                        in: RoundedRectangle(cornerRadius: Stil.eckeKarte, style: .continuous))
    }
}

/// **Normalschreibung, nicht Versalien.**
///
/// Er stand in 11 Punkt, in Grossbuchstaben, mit 1,2 gesperrt und in einem
/// eigenen „weiss 40 %" — das Muster aus iOS 6, das Apple seit Jahren nicht
/// mehr setzt. In der TV-App steht ueber einer Gruppe schlicht
/// „Automatische Wiedergabe": derselbe Grad wie eine Reihenueberschrift, in
/// gedaempftem Ton, normal geschrieben.
///
/// Und 11 Punkt war der kleinste Grad der App ueber einer Gruppe, deren
/// Zeilen 15 tragen — die Ueberschrift war leiser als das, was sie
/// ueberschreibt.
struct Gruppentitel: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(Stil.reihe)
            .tracking(Stil.sperrungReihe)
            .foregroundStyle(Stil.schriftLeise)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Gruppe mit Titel, darunter die Karte.
struct Einstellungsgruppe<Inhalt: View>: View {
    let titel: LocalizedStringKey
    @ViewBuilder let inhalt: Inhalt

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Gruppentitel(text: titel)
                .padding(.top, 26)
                .padding(.bottom, 10)
            Karte { inhalt }
        }
    }
}

/// Gruppe ohne Titel — dieselbe Karte, nur ohne Ueberschrift darueber.
struct Zeilengruppe<Inhalt: View>: View {
    @ViewBuilder let inhalt: Inhalt

    var body: some View { Karte { inhalt } }
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
        // Zeichen 15 in einer 20 breiten Spalte, 14 Abstand zum Text,
        // Titel 15 Semifett, Unterzeile 12 in `schriftSehrLeise`
        // (BAUTEILE 6). Die Unterzeile trug „weiss 45 %" — eine vierte
        // Schriftstufe neben den drei, die es gibt.
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(Stil.koerper)
                .foregroundStyle(akzent ? Stil.akzent : Stil.schriftLeise)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                titel
                    .font(Stil.listentitel)
                    .foregroundStyle(akzent ? Stil.akzent : Stil.schrift)
                if let unter {
                    unter
                        .font(Stil.klein)
                        // **Unter dem Zeiger eine Stufe heller.** Die
                        // Schwebefläche hebt den Grund, und `schriftSehrLeise`
                        // darauf fällt gerechnet unter 4,5:1. Wer eine Fläche
                        // anhebt, hebt die leisen Schriften mit (BRAND 1).
                        .foregroundStyle(schwebt ? Stil.schriftLeise
                                                 : Stil.schriftSehrLeise)
                }
            }
            Spacer(minLength: 12)
            rechts
        }
        .padding(.horizontal, 12)
        // **„14 + Inhalt + 14" als Innenabstand, nicht als feste Hoehe.**
        //
        // Hier stand `minHeight: 46` mit genau dieser Begruendung — aber eine
        // Mindesthoehe rechnet den Inhalt nicht mit. Einzeilig ging es auf:
        // rund 20 Punkt Schrift, 13 oben und unten. Eine Zeile **mit
        // Unterzeile** traegt 37 (17 Titel, 2 Abstand, 12 klein), und dann
        // blieben viereinhalb Punkt je Seite. Rückmeldung vom 22.09.: „Wiedergabe,
        // Sprache, Untertitel, Tempo — da ist gar kein Platz oben und unten,
        // da ist ja nichts zum Atmen." Quick Connect traegt dieselbe Form.
        //
        // Als Innenabstand gilt die Regel fuer beide: einzeilig 48,
        // zweizeilig 65. Die Mindesthoehe bleibt als Untergrenze fuer die
        // Trefferflaeche stehen, greift jetzt aber nur noch, wenn eine Zeile
        // ausnahmsweise weniger traegt.
        .padding(.vertical, 14)
        .frame(minHeight: 46)
        .background(schwebt ? Stil.schwebeflaeche : .clear)
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
        .buttonStyle(Stil.Druckzeile())
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
        .accessibilityRepresentation { Toggle(isOn: $an) { titel } }
    }
}

/// Der Schalter selbst — Kapsel, Akzent wenn an.
struct Schalter: View {
    let an: Bool

    var body: some View {
        // Aus: `rand`, nicht eine eigene Deckkraft — dieselbe Rolle wie
        // jeder ruhende Rand, also derselbe Token. Die Masse sind die des
        // Macs (38 × 22 statt 46 × 28): ein Zeiger trifft genauer, und die
        // Zeile ist hier 44 statt 52 hoch.
        Capsule()
            .fill(an ? Stil.akzent : Stil.rand)
            .frame(width: 38, height: 22)
            .overlay(alignment: an ? .trailing : .leading) {
                Circle()
                    .fill(an ? Stil.grund : Stil.schrift)
                    .frame(width: 16, height: 16)
                    .padding(3)
            }
            .animation(Stil.umschalten, value: an)
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
    /// Haken statt Pfeil oder Wert — für eine Wahl unter mehreren, siehe die
    /// Genre-Form in `DarstellungView`.
    var haken = false
    /// Ob die Zeile beim Überfahren hervorgehoben wird.
    ///
    /// **Standardmäßig nur, wenn sie eine eigene Aktion hat** — sonst würde
    /// eine reine Anzeigezeile so tun, als könnte man sie drücken.
    ///
    /// Steht die Zeile aber als **Beschriftung in einem äußeren Knopf**, ist
    /// sie sehr wohl drückbar und hat trotzdem keine eigene Aktion. Genau
    /// dafür ist dieser Schalter da. Vorher half man sich mit `aktion: {}`,
    /// und das war die Ursache dafür, dass „Wiedergabe" und „Einstellungen"
    /// im Profil **gar nicht reagierten**: eine leere Aktion ist nicht `nil`,
    /// also baute die Zeile einen eigenen Knopf, und der schluckte den Klick,
    /// bevor der äußere ihn sah.
    var schwebbar: Bool?

    @State private var schwebt = false

    private var hatKnopf: Bool { aktion != nil }

    var body: some View {
        // Ohne eigene Aktion **kein** Knopf: die Zeile steht dann als
        // Beschriftung in einem äußeren Knopf, und ein Knopf darin würde
        // den Klick schlucken. Derselbe Fehler wie bei den Kacheln.
        Group {
            if let aktion {
                Button(action: aktion) { rumpf }.buttonStyle(Stil.Druckzeile())
            } else {
                rumpf
            }
        }
        .onHover { schwebt = $0 && (schwebbar ?? hatKnopf) }
        .animation(Stil.zeitSchweben, value: schwebt)
    }

    private var rumpf: some View {
            Zeilenrumpf(symbol: symbol, titel: titel, unter: unter,
                        akzent: akzent, schwebt: schwebt) {
                HStack(spacing: 8) {
                    // Wert rechts 15 `schriftLeise`, Winkel 13 Semifett in
                    // `schriftSehrLeise` (BAUTEILE 6). Hier standen 14 und
                    // 12 — beide nicht auf der Leiter.
                    if let wert {
                        Text(verbatim: wert)
                            .font(Stil.koerper)
                            .foregroundStyle(Stil.schriftLeise)
                    }
                    if pfeil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Stil.schriftSehrLeise)
                    }
                    // Der Haken steht fuer eine Mehrfachwahl — dort ist das
                    // Angekreuztsein der Zustand der Sache selbst und traegt
                    // den Akzent (BRAND 1, zweite Ausnahme).
                    if haken {
                        Image(systemName: "checkmark")
                            .font(Stil.listentitel)
                            .foregroundStyle(Stil.akzent)
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
        // Eine Stufe ueber der Karte: im Dunkelmodus geht Tiefe nach oben.
        .background(Stil.flaeche)
        .overlay(alignment: .bottom) { Blattlinie() }
    }
}

private struct Wertwahlzeile: View {
    let text: String
    let gewaehlt: Bool
    let auswahl: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: auswahl) {
            // **Gewaehlt heisst Weiss, nicht Akzent** (BRAND 1). Eine
            // Wahl unter Geschwistern ist Rangfolge, und Rangfolge tragen
            // Ton und Flaeche. Der Akzent stand hier an Text und Haken.
            HStack(spacing: 8) {
                Text(verbatim: text)
                    .font(Stil.koerper)
                    .foregroundStyle(gewaehlt ? Stil.schrift : Stil.schriftLeise)
                Spacer(minLength: 0)
                if gewaehlt {
                    Image(systemName: "checkmark")
                        .font(Stil.listentitel)
                        .foregroundStyle(Stil.schrift)
                        .frame(width: 14)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Stil.zeileHoehe)
            .background(schwebt ? Stil.schwebeflaeche : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckzeile())
        .onHover { schwebt = $0 }
        // Welcher Wert gilt, hing an Ton und Haken — beides sieht VoiceOver
        // nicht. Dasselbe Merkmal setzen die Bausteine nebenan schon.
        .accessibilityAddTraits(gewaehlt ? [.isButton, .isSelected] : .isButton)
    }
}

/// Kopf einer Unterseite: Zurückpfeil und Titel nebeneinander.
///
/// Auf dem iPhone sind das zwei Dinge — ein Pfeil oben links und der Titel im
/// Inhalt. Im Fenster gibt es keinen Wisch zurück, also muss der Pfeil sichtbar
/// und treffbar sein; nebeneinander liest es sich als eine Zeile.
struct Unterseitenkopf: View {
    var titel: LocalizedStringKey = ""
    /// **Wenn die Überschrift vom Server kommt** — ein Genre heißt, wie es
    /// heißt, und darf nicht durch die Übersetzungstabelle laufen: „Action"
    /// als Schlüssel träfe dort womöglich etwas ganz anderes.
    var name: String? = nil
    let zurueck: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // **Der Rückweg ist ein blanker Pfeil** (BAUTEILE 7) — hier
            // stand ein `Aktionsknopf` mit abgeschaltetem Ring, also ein
            // Knopf, der sich als etwas anderes ausgibt.
            Rueckpfeil(zurueck: zurueck)
            Group {
                if let name { Text(verbatim: name) } else { Text(titel) }
            }
                .font(Stil.titelGross)
                .tracking(Stil.sperrungTitel)
                .foregroundStyle(Stil.schrift)
                // **Ein Name vom Server hat keine Laengengrenze.** Ohne
                // `lineLimit` brach ein langer Bibliotheks- oder
                // Servername in 28 Bold ueber drei Zeilen um und schob die
                // Seite darunter weg; er schrumpft jetzt, statt sie zu
                // verschieben — dieselbe Loesung wie auf den Detailseiten.
                .lineLimit(1)
                .minimumScaleFactor(0.62)
            Spacer(minLength: 0)
        }
    }
}
