import JellyfinKit
import Observation
import SwiftUI

/// **Rechtsklick auf eine Kachel — überall dasselbe Menü**, wie der lange
/// Druck am iPhone (`Sources/Shared/Kachelmenue.swift`): Abspielen oder
/// Fortsetzen, bei „Weiterschauen" zur Übersicht, als gesehen/ungesehen,
/// Gemeinsam schauen, bei „Weiterschauen" das Herausnehmen aus der Reihe.
/// Die Handlungen sind die vorhandenen: `Abspielsteuerung.starte`,
/// `AppModel.setzeGesehen`, `AppModel.ausWeiterschauenNehmen`,
/// `Gemeinsammodell.anlegenFuer`.
///
/// **Zwei Abweichungen, beide aus Maus und Fenster:**
/// - **Keine Vorschau.** Ein Kontextmenü am Mac ist ein AppKit-Menü am
///   Zeiger; SwiftUI zeigt dort `preview:` nicht an, und die Kachel steht
///   ohnehin unverdeckt daneben.
/// - **Kein „Laden".** Am Mac ist die Nachfrage vor einem Download eine Tafel
///   am Ladeknopf der Seite (`Macdownloads.swift`, Punkt 1) — ein Menüeintrag
///   hat keinen Knopf, an dem sie hängen könnte. Laden geht über die Seite.
struct Kachelmenue: ViewModifier {
    let item: Item
    let model: AppModel
    /// Die Kachel steht in „Weiterschauen": dann gibt es „Zur Übersicht"
    /// (ein Klick startet dort gleich) und „Aus Weiterschauen entfernen".
    var weiterschauen = false
    /// Der Weg zur Übersicht — nur bei „Weiterschauen", sonst ist der Klick
    /// selbst dieser Weg.
    var uebersicht: (() -> Void)?
    /// Nach einer Änderung am Sehstand, damit die Seite nachzieht.
    var nachher: (() async -> Void)?
    /// **Im Player: nur der Sehstand** — dieselbe Regel wie am iPhone und
    /// am Fernseher (`Sources/Shared/Kachelmenue.swift`).
    var imPlayer = false

    @Environment(Abspielsteuerung.self) private var steuerung

    /// Filme, Serien und Folgen — dieselbe Regel wie am iPhone.
    static func traegt(_ item: Item) -> Bool {
        ["Movie", "Series", "Episode"].contains(item.type ?? "")
    }

    func body(content: Content) -> some View {
        if Self.traegt(item) {
            content.contextMenu { eintraege }
        } else {
            content
        }
    }

    private var istSerie: Bool { item.type == "Series" }

    @ViewBuilder
    private var eintraege: some View {
        if !imPlayer {
            Button { abspielen() } label: {
                if !istSerie, item.fortsetzenAb != nil {
                    Label("Fortsetzen", systemImage: "play.fill")
                } else {
                    Label("Abspielen", systemImage: "play.fill")
                }
            }
        }
        if weiterschauen, let uebersicht {
            Button(action: uebersicht) {
                Label("Zur Übersicht", systemImage: "info.circle")
            }
        }
        // **Nur der Eintrag mit Wirkung** — außer bei Serien (teils gesehen)
        // und angefangenen Titeln: eine Folge, durch die man nur gesprungen
        // ist, gilt als angefangen, und „ungesehen" holt sie aus
        // „Weiterschauen". Wie am iPhone (`Shared/Kachelmenue.swift`).
        let istGesehen = item.userData?.played ?? false
        let angefangen = item.fortsetzenAb != nil
        if istSerie || !istGesehen {
            Button { gesehen(true) } label: {
                Label("Als gesehen markieren", systemImage: "checkmark.circle")
            }
        }
        if istSerie || istGesehen || angefangen {
            Button { gesehen(false) } label: {
                Label("Als ungesehen markieren", systemImage: "eye.slash")
            }
        }
        if !istSerie, !imPlayer, Gemeinsammodell.geteilt.darfAnlegen {
            Button { Gemeinsammodell.geteilt.anlegenFuer = item } label: {
                Label("Gemeinsam schauen", systemImage: "person.2")
            }
        }
        if weiterschauen {
            Button { entfernen() } label: {
                Label("Aus Weiterschauen entfernen", systemImage: "minus.circle")
            }
        }
    }

    // MARK: Handlungen

    /// Bei einer Serie die Folge, bei der man steht; die Stelle holt
    /// `Abspielsteuerung.starte` selbst frisch.
    private func abspielen() {
        let model = model, item = item, steuerung = steuerung
        Task {
            var ziel = item
            if item.type == "Series" {
                // **Gestört ist nicht „nichts mehr"** — wie am iPhone.
                do {
                    guard let stand = try await model.standInSerieGeprueft(item) else {
                        Kachelmeldung.geteilt.text = String(localized: "Danach kommt nichts mehr.")
                        return
                    }
                    ziel = stand
                } catch {
                    Kachelmeldung.geteilt.text = lesbarerFehler(error)
                    return
                }
            }
            steuerung.starte(ziel)
        }
    }

    private func gesehen(_ an: Bool) {
        let model = model, item = item, nachher = nachher
        Task {
            if let fehler = await model.setzeGesehen(item, an: an) {
                Kachelmeldung.geteilt.text = fehler
                return
            }
            await nachher?()
        }
    }

    private func entfernen() {
        let model = model, item = item, nachher = nachher
        Task {
            if let fehler = await model.ausWeiterschauenNehmen(item) {
                Kachelmeldung.geteilt.text = fehler
                return
            }
            await nachher?()
        }
    }
}

extension View {
    /// Das Kachelmenü — siehe ``Kachelmenue``.
    func kachelmenue(_ item: Item, model: AppModel, weiterschauen: Bool = false,
                     uebersicht: (() -> Void)? = nil, imPlayer: Bool = false,
                     nachher: (() async -> Void)? = nil) -> some View {
        modifier(Kachelmenue(item: item, model: model, weiterschauen: weiterschauen,
                             uebersicht: uebersicht, nachher: nachher, imPlayer: imPlayer))
    }
}

/// Was ein Kachelmenü zu sagen hat, wenn etwas scheitert — einer für die
/// ganze App, gezeigt von `HauptView` im `Hinweisstreifen` unten mittig,
/// wie jede kurze Meldung am Mac.
@MainActor
@Observable
final class Kachelmeldung {
    static let geteilt = Kachelmeldung()
    var text: String?
}

/// Der Streifen dazu. Ein Klick oder vier Sekunden nehmen ihn weg — wie
/// ``Gemeinsamfehler``.
struct Kachelmeldungsstreifen: View {
    @State private var meldung = Kachelmeldung.geteilt

    var body: some View {
        ZStack {
            if let text = meldung.text {
                Hinweisstreifen(text: text)
                    .contentShape(Capsule())
                    .onTapGesture { meldung.text = nil }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { meldung.text = nil }
                    .transition(.opacity)
                    .task(id: text) {
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled, meldung.text == text else { return }
                        meldung.text = nil
                    }
            }
        }
        .animation(Stil.einblenden, value: meldung.text)
    }
}
