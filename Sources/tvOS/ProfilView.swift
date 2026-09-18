import JellyfinKit
import SwiftUI

/// Profil und Einstellungen.
///
/// **Zwei Spalten: links die Bereiche, rechts ihre Zeilen.** So bauen Apples
/// eigene tvOS-Einstellungen auf, und der Grund ist der Weg: eine einzige
/// lange Liste zwingt zum Durchwandern, drei Spalten mit Chips nebeneinander
/// (so stand es hier zuerst) sind gar kein Aufbau, sondern eine Ablage.
///
/// Die Gruppen sind die der iPhone-Fassung — dort drei Seiten hintereinander
/// (Profil, Einstellungen, Wiedergabe), hier nebeneinander, weil Breite da
/// ist und jeder gesparte Sprung auf der Fernbedienung zählt.
struct ProfilView: View {
    let model: AppModel

    @State private var bereich: Bereichswahl = .wiedergabe
    /// Welche Wertzeile gerade ihre Auswahl zeigt.
    @State private var offen: String?
    @State private var pruefung: String?

    enum Bereichswahl: String, CaseIterable, Identifiable {
        case wiedergabe, sprachen, darstellung, server, konto
        var id: String { rawValue }
        var name: LocalizedStringKey {
            switch self {
            case .wiedergabe:  "Wiedergabe"
            case .sprachen:    "Sprachen"
            case .darstellung: "Darstellung"
            case .server:      "Server"
            case .konto:       "Konto"
            }
        }
    }

    var body: some View {
        seite
            // **Zugeklappt zurückkommen.** Wer die Einstellungen verlässt und
            // später wiederkommt, findet sonst noch die Auswahl von vorhin
            // offen — und eine halb aufgeklappte Liste sieht aus wie ein
            // Zustand, den man selbst hinterlassen hat, ohne es zu wissen.
            .onDisappear { offen = nil }
            // Dasselbe beim Wechsel des Bereichs: die Zeile, die offen war,
            // gibt es auf der neuen Seite gar nicht mehr.
            .onChange(of: bereich) { _, _ in offen = nil }
    }

    private var seite: some View {
        VStack(alignment: .leading, spacing: 0) {
            kopf.padding(.bottom, 60)

            HStack(alignment: .top, spacing: 72) {
                VStack(alignment: .leading, spacing: 0) {
                    Gruppentitel(text: "Bereiche")
                    ForEach(Bereichswahl.allCases) { b in
                        Button(b.name) { bereich = b }
                            .buttonStyle(BereichsStil(an: bereich == b))
                    }
                }
                // **Auf volle Hoehe, und zwar wegen des Fokusmotors.**
                //
                // Er bewegt den Fokus nur, wenn in der gedrueckten Richtung
                // etwas *angrenzend* und fokussierbar ist. Die Spalte war nur
                // so hoch wie ihr Inhalt; klappt rechts eine Wertzeile auf,
                // die tiefer sitzt als diese Hoehe — „Vorspulen" ist die
                // zweite —, liegt links von den Chips nichts mehr, und Links
                // tat gar nichts. Der Fokus sass fest.
                //
                // Von Koney am 03.09.2026 gemeldet. Sichtbar aendert sich
                // nichts: der Inhalt bleibt oben, nur der Abschnitt reicht
                // jetzt bis unten.
                .frame(width: 460, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .focusSection()

                // **Der Leser ist die ganze Bewegung.**
                //
                // Klappt eine Zeile auf, wird sie hierhin gescrollt — und das
                // Scrollen selbst ist die weiche Bewegung, die tvOS ohnehin
                // mitbringt. Vorher habe ich die Spalte von Hand verschoben;
                // das war hart und musste die Höhe der Auswahl raten. Hier
                // rät niemand: die Liste ist so lang, wie sie ist, und der
                // Leser bringt die aufgeklappte Zeile ins Bild.
                ScrollViewReader { leser in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Gruppentitel(text: bereich.name)
                            zeilen
                        }
                    }
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
                    .onChange(of: offen) { _, neu in
                        guard let neu else { return }
                        // Dieselbe Kurve und Dauer wie das Aufklappen —
                        // sonst laufen zwei Bewegungen gegeneinander.
                        withAnimation(.easeInOut(duration: 0.28)) {
                            leser.scrollTo(neu, anchor: .top)
                        }
                    }
                }
                .focusSection()
            }
        }
        .padding(.horizontal, Stil.randSeite)
        .padding(.vertical, Stil.randOben)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .top) {
            if let pruefung {
                Hinweisstreifen(text: pruefung) { self.pruefung = nil }
                    .padding(.top, Stil.randOben)
            }
        }
        // Seitlicher Rand: siehe `HomeView` — der Systemrand faellt weg,
        // damit `randSeite` nicht darauf sitzt und sich verdoppelt.
        .ignoresSafeArea(edges: .horizontal)
    }

    // MARK: Kopf

    private var kopf: some View {
        HStack(spacing: 32) {
            Profilzeichen(name: model.session?.userName ?? "?",
                          bild: model.benutzerbildURL(groesse: 240),
                          groesse: 60)
                .scaleEffect(1.66)
                .frame(width: 100, height: 100)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.session?.userName ?? "—")
                    .font(Stil.titelGross)
                    .foregroundStyle(Stil.schrift)
                HStack(spacing: 14) {
                    Text(model.serverName ?? "—")
                        .font(Stil.koerper)
                        .foregroundStyle(Stil.schriftLeise)
                    if let version = model.serverVersion {
                        Plakette.fern("Jellyfin \(version)")
                    }
                }
            }
        }
    }

    // MARK: Zeilen je Bereich

    @ViewBuilder
    private var zeilen: some View {
        switch bereich {
        case .wiedergabe:
            Schalterzeile(titel: "Immer Direct Play", an: model.immerDirectPlay) {
                model.immerDirectPlay.toggle()
            }
            Trennlinie()
            wertzeile("Höchste Bitrate", wert: Bitrate.text(model.bitratenGrenze),
                      eintraege: Bitrate.stufen, beschriftung: { Bitrate.text($0.wert) },
                      an: { $0.wert == model.bitratenGrenze },
                      waehlen: { model.bitratenGrenze = $0.wert })
            Trennlinie()
            Schalterzeile(titel: "Untertitel automatisch", an: model.untertitelAutomatisch) {
                model.untertitelAutomatisch.toggle()
            }
            Trennlinie()
            Schalterzeile(titel: "Nächste Folge automatisch", an: model.naechsteAutomatisch) {
                model.naechsteAutomatisch.toggle()
            }
            Trennlinie()
            wertzeile("Zurückspulen", wert: "\(model.zurueckSekunden) s",
                      eintraege: Spanne.stufen, beschriftung: { "\($0.wert) s" },
                      an: { $0.wert == model.zurueckSekunden },
                      waehlen: { model.zurueckSekunden = $0.wert })
            Trennlinie()
            wertzeile("Vorspulen", wert: "\(model.vorSekunden) s",
                      eintraege: Spanne.stufen, beschriftung: { "\($0.wert) s" },
                      an: { $0.wert == model.vorSekunden },
                      waehlen: { model.vorSekunden = $0.wert })

        case .sprachen:
            wertzeile("Ton",
                      wert: model.tonSprache.isEmpty ? String(localized: "Wie die Datei")
                                                     : model.tonSprache,
                      eintraege: Sprachwahl.alle, beschriftung: \.name,
                      an: { $0.wert == model.tonSprache },
                      waehlen: { model.tonSprache = $0.wert })
            Trennlinie()
            wertzeile("Untertitel",
                      wert: model.untertitelSprache.isEmpty ? String(localized: "Aus")
                                                            : model.untertitelSprache,
                      eintraege: Sprachwahl.alle(aus: String(localized: "Aus")),
                      beschriftung: \.name,
                      an: { $0.wert == model.untertitelSprache },
                      waehlen: { model.untertitelSprache = $0.wert })

        case .darstellung:
            Schalterzeile(titel: "Fortschritt auf Kacheln", an: model.fortschrittAufKacheln) {
                model.fortschrittAufKacheln.toggle()
            }

        case .server:
            Anzeigezeile(titel: "Adresse", wert: model.serverName ?? "—")
            Trennlinie()
            Anzeigezeile(titel: "Fassung", wert: model.serverVersion.map { "Jellyfin \($0)" } ?? "—")
            Trennlinie()
            Handlungszeile(titel: "Verbindung prüfen") {
                Task { pruefung = await model.verbindungPruefen() }
            }

        case .konto:
            Handlungszeile(titel: "Abmelden") { model.signOut() }
        }
    }

    /// Zeile mit Wert rechts. Drücken klappt die Auswahl darunter auf —
    /// statt sie in ein Blatt zu legen, das wieder Wege kostet.
    private func wertzeile<E: Identifiable>(_ titel: LocalizedStringKey, wert: String,
                                            eintraege: [E],
                                            beschriftung: @escaping (E) -> String,
                                            an: @escaping (E) -> Bool,
                                            waehlen: @escaping (E) -> Void) -> some View {
        let schluessel = String(describing: titel)
        return VStack(alignment: .leading, spacing: 0) {
            Handlungszeile(titel: titel, wert: wert,
                           aufgeklappt: offen == schluessel) {
                // **Ein Vorgang für die ganze Liste, nicht einer je Zeile.**
                //
                // Hier hing ein `.animation(…, value: offen)` an jeder
                // Wertzeile. Damit animiert jede für sich: die zwei direkt
                // darunter standen sofort an ihrem neuen Platz, die weiter
                // unten rutschten langsam nach, und dazwischen überlappten
                // sie sich. Ein `withAnimation` an der Änderung selbst legt
                // alle in **eine** Bewegung — die Liste rückt als ein Stück.
                withAnimation(.easeInOut(duration: 0.28)) {
                    offen = offen == schluessel ? nil : schluessel
                }
            }

            if offen == schluessel {
                // **Dieselbe Zeilenform, nur eingerückt.** Vorher standen
                // hier runde Marken nebeneinander; Paul: „mach doch nicht,
                // dass da unsere komischen runden Dinger sind." Eine Auswahl
                // sieht in einer Einstellungsliste aus wie die Liste — mit
                // Haken beim Gewählten, so wie es jede App macht.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(eintraege) { eintrag in
                        Button {
                            waehlen(eintrag)
                            offen = nil
                        } label: {
                            HStack(spacing: 24) {
                                Image(systemName: an(eintrag)
                                      ? "checkmark" : "")
                                    .font(.system(size: 26, weight: .semibold))
                                    .foregroundStyle(Stil.akzent)
                                    .frame(width: 34)
                                // Interpoliert, nicht als Schlüssel: „30 s"
                                // ist ein Wert und stünde sonst als
                                // Fehlstelle im Katalog.
                                Text("\(beschriftung(eintrag))")
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(ZeilenStil())
                    }
                }
                .padding(.leading, 26)
                .focusSection()
                .transition(.opacity)
            }
        }
        // Ziel für den Leser, damit die aufgeklappte Zeile ins Bild kommt.
        .id(schluessel)
    }
}

// MARK: - Zeilen

/// Ein Bereich in der linken Spalte. Gewählt ist Akzent, fokussiert die
/// ruhige Fläche — dieselbe Regel wie überall.
struct BereichsStil: ButtonStyle {
    let an: Bool

    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration, an: an)
    }

    private struct Inhalt: View {
        let configuration: ButtonStyleConfiguration
        let an: Bool
        @Environment(\.isFocused) private var fokus

        var body: some View {
            configuration.label
                .font(.system(size: 31, weight: an ? .semibold : .medium))
                .foregroundStyle(an ? Stil.grund : Stil.schrift)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
                .frame(height: Stil.zeilenHoehe)
                .background(an ? Stil.akzent : (fokus ? Stil.fokusflaeche : .clear),
                            in: RoundedRectangle(cornerRadius: Stil.ecke))
                .animation(Stil.fokusAnimation, value: fokus)
        }
    }
}

/// Zeile ohne Handlung — nur Angabe.
struct Anzeigezeile: View {
    let titel: LocalizedStringKey
    let wert: String

    var body: some View {
        HStack(spacing: 24) {
            Text(titel).font(.system(size: 31, weight: .medium))
            Spacer(minLength: 40)
            Text(wert).font(Stil.knopf).foregroundStyle(Stil.schriftLeise)
        }
        .foregroundStyle(Stil.schrift)
        .padding(.horizontal, 26)
        .frame(height: Stil.zeilenHoehe)
    }
}

/// Zeile, die etwas auslöst — mit oder ohne Wert rechts.
struct Handlungszeile: View {
    let titel: LocalizedStringKey
    var wert: String?
    var aufgeklappt = false
    let aktion: () -> Void

    var body: some View {
        Button(action: aktion) {
            HStack(spacing: 24) {
                Text(titel)
                Spacer(minLength: 40)
                if let wert {
                    Text(wert).foregroundStyle(Stil.schriftLeise)
                    Image(systemName: aufgeklappt ? "chevron.up" : "chevron.down")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Stil.schriftSehrLeise)
                }
            }
        }
        .buttonStyle(ZeilenStil())
    }
}

/// Zeile mit Schalter rechts.
///
/// Kein `Toggle`: Apples Schalter bringt eigene Maße, eigenen Radius und
/// eigene Animation mit — dieselbe Begründung wie auf dem iPhone. Auf tvOS
/// kommt dazu, dass der Fokus auf der ganzen Zeile liegt, nicht auf dem
/// Schalter; gedrückt wird die Zeile.
struct Schalterzeile: View {
    let titel: LocalizedStringKey
    let an: Bool
    let aktion: () -> Void

    var body: some View {
        Button(action: aktion) {
            HStack(spacing: 24) {
                Text(titel)
                Spacer(minLength: 40)
                Schalter(an: an)
            }
        }
        .buttonStyle(ZeilenStil())
        .accessibilityRepresentation {
            Toggle(isOn: .constant(an)) { Text(titel) }
        }
    }
}

/// Der Schalter selbst — nur Anzeige, gedrückt wird die Zeile.
struct Schalter: View {
    let an: Bool

    var body: some View {
        ZStack(alignment: an ? .trailing : .leading) {
            Capsule()
                .fill(an ? Stil.akzent : Color.white.opacity(0.16))
                .frame(width: 84, height: 50)
            Circle()
                .fill(an ? Stil.grund : Color.white)
                .frame(width: 40, height: 40)
                .padding(.horizontal, 5)
        }
        .animation(.easeInOut(duration: 0.15), value: an)
    }
}

/// Haarlinie zwischen Zeilen.
struct Trennlinie: View {
    var body: some View {
        Rectangle().fill(Stil.linie)
            .frame(height: 2)
            .padding(.horizontal, 26)
    }
}
