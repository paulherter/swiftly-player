import Foundation
import JellyfinKit

// **Wozu.** Am 05.09.2026 zeigte die ausgelieferte 1.0.0 jedem Nutzer eine
// halb deutsche, halb englische Oberfläche, egal welche Sprache sein System
// hatte — und niemand hatte es gemessen. Diese Probe misst es: sie ruft
// dieselben Funktionen auf, die die App aufruft, und zeigt, was dabei
// herauskommt.
//
//     swift run Sprachprobe [Pfad zu SwiftlyLinux_SwiftlyLinux.resources]
//
// Sinnvoll ist sie nur mit gesetzter Sprache, also etwa
//
//     LANG=en_US.UTF-8 swift run Sprachprobe …
//
// Der Pfad zum Bündel der Oberfläche ist wahlfrei; ohne ihn prüft die Probe
// nur den Katalog des Pakets.

func kopf(_ text: String) { print("\n── \(text) ──") }

let umgebung = ProcessInfo.processInfo.environment
print("Umgebung:", ["LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"]
    .map { "\($0)=\(umgebung[$0] ?? "—")" }.joined(separator: "  "))

// MARK: Der Katalog des Pakets, über echte API

kopf("JellyfinKit — schlichte Schlüssel")
// `lesbarerFehler` läuft durch `uebersetzt`; hier ohne Platzhalter.
print("  401              :", lesbarerFehler(JellyfinError.http(status: 401, body: nil)))
print("  nicht angemeldet :", lesbarerFehler(JellyfinError.notAuthenticated))

kopf("JellyfinKit — Schlüssel mit Interpolation")
// Auf Linux stand hier bis 1.0.0 der ausgerechnete Text als Schlüssel
// („Staffel 3“), der in keinem Katalog steht.
print("  laufzeit(7680)   :", laufzeit(7680))   // Schlüssel „%lld Std. %lld Min.“
print("  laufzeit(5640)   :", laufzeit(5640))   // Schlüssel „%lld Min.“
print("  Status 418       :", lesbarerFehler(JellyfinError.http(status: 418, body: nil)))

func item(_ json: String) -> Item {
    try! JSONDecoder().decode(Item.self, from: Data(json.utf8))
}

print("  Folge, Staffel 3 :",
      item(#"{"Id":"1","Name":"Folge","Type":"Episode","ParentIndexNumber":3}"#).neuzugangszeile ?? "—")

kopf("JellyfinKit — Mehrzahl (Localizable.stringsdict)")
for anzahl in [1, 5] {
    let zeile = item(#"{"Id":"1","Name":"Serie","Type":"Series","ChildCount":\#(anzahl)}"#).neuzugangszeile
    print("  ChildCount \(anzahl)     :", zeile ?? "—")
}

// MARK: Der Katalog der Oberfläche

if CommandLine.arguments.count > 1 {
    let pfad = CommandLine.arguments[1]
    kopf("SwiftlyLinux — \(pfad)")
    if let buendel = Bundle(path: pfad) {
        // Genau das, was `uebersetzt(_:)` in der Oberfläche tut.
        let katalog = Textkatalog(bundle: buendel)
        print("  Sprache gewählt  :", katalog.sprache)
        for schluessel in ["Anmelden", "Einstellungen", "Zuletzt hinzugefügt", "Suchen",
                           "%d Sekunden vor", "Diesen Schlüssel gibt es nicht"] {
            print("  \(schluessel.padding(toLength: 22, withPad: " ", startingAt: 0)):",
                  katalog.text(Textschluessel(schluessel)))
        }
    } else {
        print("  Bündel nicht gefunden")
    }
}
