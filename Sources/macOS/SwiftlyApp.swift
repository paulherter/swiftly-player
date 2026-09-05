import AppKit
import SwiftUI

/// Einstieg der Mac-Fassung.
///
/// `hiddenTitleBar` lässt den Inhalt bis unter die Fensterknöpfe laufen — die
/// Seitenleiste hält oben `Stil.titelHoehe` frei, damit die Wortmarke nicht
/// unter den drei Punkten liegt. Ohne das säße über allem eine graue Leiste,
/// die zu einer flachen, dunklen Gestaltung nicht passt.
@main
struct SwiftlyApp: App {

    /// Die Kennung des einen Fensters. Als Konstante, damit sie beim Öffnen
    /// aus dem Menü und beim Erklären dieselbe ist.
    static let hauptfenster = "hauptfenster"

    /// **Damit das Schliessen des Fensters die App nicht beendet.**
    ///
    /// Gemessen: ein `Window` ohne diesen Delegaten beendet das Programm,
    /// sobald sein einziges Fenster zugeht. Das waere Apples zweiter
    /// zulaessiger Weg — fuer einen Abspieler aber unueblich: Musik, TV, VLC
    /// und IINA bleiben alle stehen. Mit `false` bleibt die App im Dock, und
    /// SwiftUI fuehrt das zugegangene Fenster im Menue „Fenster".
    @NSApplicationDelegateAdaptor(Anwendungsdelegat.self) private var delegat

    var body: some Scene {
        // **`Window`, nicht `WindowGroup`.** Zwei Gruende, und der zweite ist
        // der wichtigere.
        //
        // 1. Apple hat 1.0.0 (8) nach Richtlinie 4 abgewiesen: „when the user
        //    closes the main application window there is no menu item to
        //    re-open it." Ein `Window` ist ein einzelnes, benanntes Fenster —
        //    SwiftUI führt es dauerhaft im Menü „Fenster", auch wenn es zu
        //    ist. Bei `WindowGroup` stand dort nur der Eintrag der offenen
        //    Fensterliste.
        // 2. **Zwei Fenster kann diese App gar nicht.** `AppModel` liegt als
        //    `@State` in `RootView`; jedes weitere Fenster bekäme ein eigenes,
        //    also eine zweite, nicht angemeldete App im selben Programm. Der
        //    Eintrag „Neues Fenster" war deshalb schon vorher entfernt — und
        //    damit auch der einzige Weg zurück. Genau diese Lücke hat Apple
        //    gesehen.
        Window(Text(verbatim: "Swiftly"), id: Self.hauptfenster) {
            RootView()
                .frame(minWidth: Stil.fensterMinBreite, minHeight: Stil.fensterMinHoehe)
                // Ein helles Thema gibt es nicht — die Gestaltung ist auf
                // Dunkel gebaut. Wörtlich aus der iPhone-Fassung.
                .preferredColorScheme(.dark)
                .tint(Stil.akzent)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands { Menueleiste() }
    }
}

/// Die Menüleiste gehört zum Mac — aber sie bietet **nichts** an, was die
/// Oberfläche nicht auch zeigt. Sie ist der zweite Weg zu denselben
/// Handlungen, kein eigener Vorrat.
///
/// Die Befehle laufen deshalb über `Kommando` als Nachricht an die Ansicht,
/// statt hier eigene Logik zu tragen.
struct Menueleiste: Commands {
    var body: some Commands {
        // Apples Vorgaben, die es nicht braucht: keine Tellerränder wie
        // „Drucken" oder „Neu". **Ein neues Fenster gibt es nicht** — siehe
        // die Begründung an der Szene: zwei Fenster kann diese App nicht.
        CommandGroup(replacing: .newItem) {}

        // **Der Weg zurück zum Fenster.** Apple hat 1.0.0 (8) genau hier
        // abgewiesen: „when the user closes the main application window there
        // is no menu item to re-open it."
        //
        // Nachgemessen, nicht angenommen: weder `WindowGroup` noch `Window`
        // stellen von sich aus einen Eintrag hin, der ein **zugegangenes**
        // Fenster zurückholt. `WindowGroup` führte nur die offene Fensterliste
        // — steht das Fenster, verschwindet der Eintrag. Bei `Window` war das
        // Menü „Fenster" auch mit offenem Fenster leer bis auf „Im Dock
        // ablegen", „Zoomen" und „Alle nach vorne bringen". Also selbst
        // hinstellen.
        CommandGroup(after: .singleWindowList) { Fensteroeffner() }

        CommandMenu(Text("Gehe zu")) {
            Kommandoknopf("Start",  .start,  "1")
            Kommandoknopf("Filme",  .filme,  "2")
            Kommandoknopf("Serien", .serien, "3")
            Divider()
            Kommandoknopf("Suchen", .suche,  "f")
            Divider()
            Kommandoknopf("Zurück", .zurueck, "[")
        }
    }
}

/// Was die Menüleiste auslösen kann. Absichtlich klein: jeder Fall hat eine
/// sichtbare Entsprechung in der Oberfläche.
enum Kommando: String {
    case start, filme, serien, suche, zurueck
}

/// Ein Menüeintrag, der sein Kommando als Nachricht schickt.
///
/// Über `NotificationCenter` und nicht über einen gemeinsamen Zustandshalter:
/// die Menüleiste lebt außerhalb jeder Ansicht, und bei mehreren Fenstern
/// gäbe es sonst keinen Weg zu entscheiden, welches gemeint ist — das
/// vorderste hört zu, die anderen nicht.
struct Kommandoknopf: View {
    let beschriftung: LocalizedStringKey
    let kommando: Kommando
    let taste: KeyEquivalent

    init(_ beschriftung: LocalizedStringKey, _ kommando: Kommando, _ taste: KeyEquivalent) {
        self.beschriftung = beschriftung
        self.kommando = kommando
        self.taste = taste
    }

    var body: some View {
        Button(beschriftung) { Kommandopost.senden(kommando) }
            .keyboardShortcut(taste, modifiers: .command)
    }
}

/// Der Draht zwischen Menüleiste und Ansicht.
enum Kommandopost {
    static let name = Notification.Name("de.paulherter.swiftly.kommando")

    static func senden(_ kommando: Kommando) {
        NotificationCenter.default.post(name: name, object: nil,
                                        userInfo: ["k": kommando.rawValue])
    }

    static func empfangen(_ nachricht: Notification) -> Kommando? {
        guard let roh = nachricht.userInfo?["k"] as? String else { return nil }
        return Kommando(rawValue: roh)
    }
}

/// Nur eine Frage beantwortet dieser Delegat, und die stellt AppKit von selbst.
@MainActor
final class Anwendungsdelegat: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
}

/// „Fenster → Swiftly" — holt das Hauptfenster zurück, wenn es zu ist, und
/// nach vorn, wenn es offen ist. Beides macht `openWindow` von selbst.
///
/// Eigene Ansicht und nicht ein Knopf im `Commands`-Rumpf: `openWindow` kommt
/// aus der Umgebung, und die gibt es nur in einer `View`.
struct Fensteroeffner: View {
    @Environment(\.openWindow) private var oeffne

    var body: some View {
        Button { oeffne(id: SwiftlyApp.hauptfenster) } label: {
            Text(verbatim: "Swiftly")
        }
        .keyboardShortcut("0", modifiers: .command)
    }
}
