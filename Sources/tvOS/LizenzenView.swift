import SwiftUI

// **Swiftly → Open-Source-Lizenzen (Apple TV).**
//
// Links die Bausteine, rechts, was zum gerade angefahrenen gehört: Angaben,
// Quelle und der Volltext. Der Fernseher hat keinen Zeiger und keinen
// Browser — also ist jeder Absatz rechts **fokussierbar**, und gescrollt wird
// durch Weiterrücken des Fokus, wie es die Fernbedienung ohnehin tut.
// Adressen stehen als Text da, zum Abtippen. Die Daten kommen aus
// `Lizenzbestand`, derselben Quelle wie auf den anderen Plattformen; der
// Wortlaut der Lizenzen bleibt englisch.

struct TVLizenzenView: View {
    let schliessen: () -> Void

    private enum Wahl: Hashable {
        case angebot
        case baustein(String)
    }
    private enum Ort: Hashable {
        case links(Wahl)
        case rechts(Int)
    }

    private let bestand = Lizenzbestand.geteilt
    @State private var wahl: Wahl = .angebot
    @FocusState private var ort: Ort?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Stil.grund.ignoresSafeArea()
            HStack(alignment: .top, spacing: 72) {
                links
                    .frame(width: 560, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .focusSection()
                rechts
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .focusSection()
            }
            .padding(.horizontal, Stil.randSeite)
            .padding(.vertical, Stil.randOben)
        }
        .ignoresSafeArea(edges: .horizontal)
        .defaultFocus($ort, .links(.angebot))
        .onChange(of: ort) { _, neu in
            if case let .links(w) = neu { wahl = w }
        }
        // Zurück aus dem Text führt zuerst zur Liste; erst ein zweites Zurück
        // verlässt die Seite — wie im Profil.
        .onExitCommand {
            if case .rechts = ort { ort = .links(wahl) } else { schliessen() }
        }
    }

    // MARK: Links

    private var links: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Open-Source-Lizenzen")
                .font(Stil.titelGross)
                .foregroundStyle(Stil.schrift)
                .padding(.leading, 26)
                .padding(.bottom, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let bestand {
                        Gruppentitel(text: "VLCKit und libVLC")
                        ForEach(bestand.bausteine(gruppe: "player")) { b in zeile(.baustein(b.id), b.name) }
                        zeile(.angebot, String(localized: "Quelltext und schriftliches Angebot"))
                        gruppe("Weitere Bausteine", bestand.bausteine(gruppe: "app"))
                        gruppe("In VLCKit eingebaut", bestand.bausteine(gruppe: "in-vlckit"))
                    } else {
                        zeile(.angebot, String(localized: "Quelltext und schriftliches Angebot"))
                    }
                }
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    @ViewBuilder
    private func gruppe(_ titel: LocalizedStringKey, _ liste: [Lizenzbaustein]) -> some View {
        if !liste.isEmpty {
            Gruppentitel(text: titel).padding(.top, 36)
            ForEach(liste) { b in zeile(.baustein(b.id), b.name) }
        }
    }

    private func zeile(_ ziel: Wahl, _ name: String) -> some View {
        Handlungszeile(name: name) { ort = .rechts(0) }
            .focused($ort, equals: .links(ziel))
    }

    // MARK: Rechts

    private var rechts: some View {
        let bloecke = self.bloecke
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(bloecke.enumerated()), id: \.offset) { stelle, block in
                    Button {} label: {
                        Text(verbatim: block.text)
                            .font(block.titel ? Stil.reihe : Stil.koerper)
                            .lineSpacing(5)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(Lizenzblockstil(titel: block.titel))
                    .focused($ort, equals: .rechts(stelle))
                }
            }
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .id(wahl)
    }

    private struct Block {
        let text: String
        var titel = false
    }

    private var bloecke: [Block] {
        guard let bestand else {
            return [Block(text: String(localized: "Die Lizenzliste fehlt in dieser Fassung. Du findest sie auf GitHub in THIRD-PARTY-NOTICES.md."))]
        }
        switch wahl {
        case .angebot:
            var ergebnis: [Block] = [Block(text: bestand.angebot.titel, titel: true)]
            for abschnitt in bestand.angebot.abschnitte {
                ergebnis.append(Block(text: abschnitt.titel, titel: true))
                ergebnis += abschnitt.absaetze.map { Block(text: $0) }
            }
            return ergebnis
        case let .baustein(id):
            guard let b = bestand.baustein(id: id) else { return [] }
            var ergebnis: [Block] = [
                Block(text: b.name, titel: true),
                Block(text: "\(String(localized: "Fassung")): \(b.version)\n\(String(localized: "Lizenz")): \(b.spdx)\n\(String(localized: "Urheber")): \(b.urheber)\n\(String(localized: "Quelle")): \(b.quelle)"),
            ]
            if let notiz = b.notiz { ergebnis.append(Block(text: notiz)) }
            for datei in b.texte {
                guard let text = Lizenzbestand.text(datei) else {
                    ergebnis.append(Block(text: String(localized: "Der Text fehlt in dieser Fassung.")))
                    continue
                }
                ergebnis.append(Block(text: String(localized: "Lizenztext"), titel: true))
                ergebnis += Lizenzbestand.absaetze(von: text).map { Block(text: $0) }
            }
            return ergebnis
        }
    }
}

/// Ein Absatz im Volltext: ruht flach, trägt im Fokus dieselbe ruhige Fläche
/// wie jede Zeile der App.
private struct Lizenzblockstil: ButtonStyle {
    let titel: Bool

    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration, titel: titel)
    }

    private struct Inhalt: View {
        let configuration: ButtonStyleConfiguration
        let titel: Bool
        @Environment(\.isFocused) private var fokus

        var body: some View {
            configuration.label
                .foregroundStyle(titel || fokus ? Stil.schrift : Stil.schriftLeise)
                .padding(.horizontal, 26)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(fokus ? Stil.fokusflaeche : Color.clear,
                            in: RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous))
                .animation(Stil.fokusAnimation, value: fokus)
        }
    }
}
