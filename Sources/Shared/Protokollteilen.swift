#if os(iOS) || os(macOS)
import JellyfinKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// **„Protokoll teilen" — die letzte Stunde als Textdatei.**
///
/// Für Fehler, die nur beim Nutzer auftreten: er stellt ihn nach, tippt
/// hier, und schickt die Datei über das Teilen-Blatt, meist in den Discord.
/// Die Zeilen kommen aus ``Protokollring``; Zugangsmerkmale sind dort schon
/// beim Eintragen geschwärzt. Die Serveradresse bleibt stehen — ohne sie
/// lässt sich ein Netzfehler nicht lesen.
struct Protokolldatei: Identifiable {
    let url: URL
    var id: String { url.path }

    @MainActor
    static func schreiben() -> Protokolldatei? {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var zeilen = [
            "Swiftly \(Fassung.mitUnterbau)",
            system(v),
            "Stand \(ISO8601DateFormatter().string(from: Date()))",
            "",
        ]
        let auszug = Protokollring.geteilt.auszug(sekunden: 3600)
        zeilen += auszug.isEmpty
            ? ["(no lines in the last hour — reproduce the problem first, then share without closing the app)"]
            : auszug
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Swiftly-Protokoll.txt")
        do {
            try Data(zeilen.joined(separator: "\n").utf8).write(to: url, options: .atomic)
        } catch {
            Protokoll.schreib("[Protokoll] Datei ließ sich nicht schreiben: \(error.localizedDescription)")
            return nil
        }
        return Protokolldatei(url: url)
    }

    private static func system(_ v: OperatingSystemVersion) -> String {
        #if os(iOS)
        "iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) · \(UIDevice.current.model)"
        #else
        "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }
}

#if os(iOS)

/// Das System-Teilen-Blatt für eine Datei.
struct Teilenblatt: UIViewControllerRepresentable {
    let datei: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [datei], applicationActivities: nil)
    }

    func updateUIViewController(_ blatt: UIActivityViewController, context: Context) {}
}
#endif
#endif
