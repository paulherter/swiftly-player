import JellyfinKit
import SwiftUI

/// Anmelden, ohne ein Passwort zu tippen.
///
/// Die Gegenrichtung zu der Quick-Connect-Seite im Profil: dort gibt dieses
/// Gerät einen fremden Code frei, hier lässt es sich selbst freigeben. Der
/// Code ist das Einzige, was zählt — deshalb steht er groß und in einzelnen
/// Feldern, damit man sich beim Abtippen nicht verzählt.
struct QuickConnectAnmeldung: View {
    let model: AppModel
    /// Am Server, der gerade hinzugefügt wird. Dann meldet `fertig`, dass
    /// die Anmeldung dort geklappt hat.
    var neuerServer = false
    var fertig: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    /// Der Ablauf steht in `QuickConnectModell` — geteilt mit der
    /// tvOS-Fassung.
    @State private var stand = QuickConnectModell()

    /// **Die einzige Seite der Fassung, die das nicht gelesen hat.**
    /// Fester Innenabstand von 28 und volle Breite — auf dem iPad stand der
    /// Erklaertext damit ueber 1036 Punkt, also 140 Zeichen je Zeile.
    @Environment(\.breit) private var breit

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Titel neben dem Pfeil, wie auf den anderen Menues.
                    Unterseitenkopf(titel: String(localized: "Quick Connect")) { dismiss() }
                        .padding(.horizontal, -Stil.rand(breit: breit))

                    Text("Gib diesen Code in Jellyfin auf einem Gerät ein, an dem du schon angemeldet bist.")
                        .font(Stil.koerper)
                        .foregroundStyle(Stil.schriftLeise)
                        .lineSpacing(3)
                        .padding(.top, 10)

                    if let vorgang = stand.vorgang {
                        // Ein Tipp legt den Code in die Zwischenablage —
                        // meist wird er gleich daneben eingefügt.
                        codefelder(vorgang.code)
                            .kopierbar(vorgang.code)
                        wartezeile
                    } else if let fehler = stand.fehler {
                        Text(fehler)
                            .font(Stil.koerper)
                            // `fehler`, nicht `warnung`: der Code kam nicht
                            // zustande. `warnung` heisst „etwas wartet auf
                            // jemanden" — hier wartet nichts mehr.
                            .foregroundStyle(Stil.fehler)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        // Der Code kommt gleich; solange steht seine Form da.
                        Ladefeld(ecke: Stil.eckeFeld)
                            .frame(height: 60)
                            .frame(maxWidth: 260)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }

                    anleitung
                }
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.bottom, 40)
                // Dasselbe Mass wie Anmeldung und Server.
                .frame(maxWidth: Stil.formularbreite)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .contentMargins(.top, 8, for: .scrollContent)
        }
        .safeAreaInset(edge: .bottom) {
            Button("Neuen Code holen") { Task { await neuStarten() } }
                .buttonStyle(NebenknopfStil())
                .padding(.horizontal, Stil.rand(breit: breit))
                .frame(maxWidth: Stil.formularbreite)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
        .task {
            stand.neuerServer = neuerServer
            await neuStarten()
        }
        .onDisappear { stand.anhalten() }
        .onChange(of: stand.freigegeben) { _, neu in
            guard let neu else { return }
            dismiss()
            Task {
                if neuerServer {
                    if await model.anmeldenMitQuickConnectAmNeuenServer(neu) { fertig() }
                } else {
                    await model.anmeldenMitQuickConnect(neu)
                }
            }
        }
    }

    /// Einzelne Felder statt einer Zeichenkette: sechs Ziffern am Stück liest
    /// niemand fehlerfrei vom Bildschirm ab.
    private func codefelder(_ code: String) -> some View {
        let zeichen = Array(code)
        return HStack(spacing: 8) {
            ForEach(Array(zeichen.enumerated()), id: \.offset) { paar in
                if paar.offset == zeichen.count / 2 {
                    Color.clear.frame(width: 6)
                }
                Text(String(paar.element))
                    // Der Grad kommt aus der Leiter, das Gewicht nicht: 28 ist
                    // die Stufe des Seitentitels, und Bold steht genau einmal
                    // — am Titel. Der Code ist die Hauptsache der Seite, aber
                    // kein Titel. Vorher `.system(size: 28, weight: .semibold)`.
                    .font(Stil.titelGross)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(Stil.schrift)
                    .frame(width: 46, height: 60)
                    .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.eckeFeld, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 34)
    }

    /// Ohne Restzeit weiß niemand, ob überhaupt noch etwas passiert.
    private var wartezeile: some View {
        HStack(spacing: 9) {
            Circle().fill(Stil.akzent).frame(width: 8, height: 8)
            Text("Warte auf Freigabe · noch \(stand.restsekunden / 60):\(String(format: "%02d", stand.restsekunden % 60))")
                // 12 Regular aus der Leiter; 13 Regular steht dort nicht.
                // Vorher 13.
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftLeise)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
    }

    private var anleitung: some View {
        VStack(alignment: .leading, spacing: 0) {
            Trennlinie()
            Gruppentitel(text: "So gehts")
            schritt(1, "Jellyfin im Browser öffnen und anmelden")
            schritt(2, "Oben rechts aufs Profil, dann Quick Connect")
            schritt(3, "Code eingeben, dann geht es hier von selbst weiter")
        }
        .padding(.top, 38)
    }

    private func schritt(_ zahl: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(zahl)")
                // 12 Regular aus der Leiter, wie die Schrittzeile daneben.
                // Vorher 13.
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftSehrLeise)
                .frame(width: 20, alignment: .leading)
            Text(text)
                // 12 Regular aus der Leiter. Vorher 13.
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftLeise)
                .lineSpacing(2)
        }
        .padding(.top, 10)
    }

    // MARK: - Ablauf

    /// Erst zumachen, dann anmelden: die Anmeldung tauscht die ganze
    /// Ansicht aus, und ein Vorhang, der über einer ausgetauschten Ansicht
    /// liegt, blitzt auf.
    private func neuStarten() async {
        await stand.neuStarten(model)
    }
}
