import SwiftUI

/// Einstieg der Mac-Fassung.
///
/// `hiddenTitleBar` lässt den Inhalt bis unter die Fensterknöpfe laufen — die
/// Seitenleiste hält oben `Stil.titelHoehe` frei, damit die Wortmarke nicht
/// unter den drei Punkten liegt. Ohne das säße über allem eine graue Leiste,
/// die zu einer flachen, dunklen Gestaltung nicht passt.
@main
struct SwiftlyApp: App {

    var body: some Scene {
        WindowGroup {
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
        // Apples Vorgaben, die es nicht braucht: neues Fenster gibt es, aber
        // keine Tellerränder wie „Drucken" oder „Neu".
        CommandGroup(replacing: .newItem) {}

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
