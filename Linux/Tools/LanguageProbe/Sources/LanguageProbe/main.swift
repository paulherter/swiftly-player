import Foundation
import JellyfinKit

// **Purpose.** A released version once showed every user a half German, half
// English UI regardless of the system language, and nobody had measured it.
// This probe measures it: it calls the same functions the app calls and shows
// what comes out.
//
//     swift run LanguageProbe [path to SwiftlyLinux_SwiftlyLinux.resources]
//
// Only useful with a language set, e.g.
//
//     LANG=en_US.UTF-8 swift run LanguageProbe ...
//
// The path to the UI bundle is optional; without it the probe only checks the
// package catalog.

func header(_ text: String) { print("\n── \(text) ──") }

let environment = ProcessInfo.processInfo.environment
print("Umgebung:", ["LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"]
    .map { "\($0)=\(environment[$0] ?? "—")" }.joined(separator: "  "))

// MARK: The package catalog, through the real API

header("JellyfinKit — schlichte Schlüssel")
// `readableError` goes through `translated`; no placeholders here.
print("  401              :", readableError(JellyfinError.http(status: 401, body: nil)))
print("  nicht angemeldet :", readableError(JellyfinError.notAuthenticated))

header("JellyfinKit — Schlüssel mit Interpolation")
// On Linux this used to return the computed text as a key ("Staffel 3"),
// which is in no catalog.
print("  laufzeit(7680)   :", runtime(7680))   // key "%lld Std. %lld Min."
print("  laufzeit(5640)   :", runtime(5640))   // key "%lld Min."
print("  Status 418       :", readableError(JellyfinError.http(status: 418, body: nil)))

func item(_ json: String) -> Item {
    try! JSONDecoder().decode(Item.self, from: Data(json.utf8))
}

print("  Folge, Staffel 3 :",
      item(#"{"Id":"1","Name":"Folge","Type":"Episode","ParentIndexNumber":3}"#).newArrivalsRow ?? "—")

header("JellyfinKit — Mehrzahl (Localizable.stringsdict)")
for count in [1, 5] {
    let row = item(#"{"Id":"1","Name":"Serie","Type":"Series","ChildCount":\#(count)}"#).newArrivalsRow
    print("  ChildCount \(count)     :", row ?? "—")
}

// MARK: The UI catalog

if CommandLine.arguments.count > 1 {
    let path = CommandLine.arguments[1]
    header("SwiftlyLinux — \(path)")
    if let bundle = Bundle(path: path) {
        // Exactly what `translated(_:)` does in the UI.
        let catalog = TextCatalog(bundle: bundle)
        print("  Sprache gewählt  :", catalog.language)
        for key in ["Anmelden", "Einstellungen", "Zuletzt hinzugefügt", "Suchen",
                           "%d Sekunden vor", "Diesen Schlüssel gibt es nicht"] {
            print("  \(key.padding(toLength: 22, withPad: " ", startingAt: 0)):",
                  catalog.text(TextKey(key)))
        }
    } else {
        print("  Bündel nicht gefunden")
    }
}
