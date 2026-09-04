import CGtk
import Foundation

/// **Das Anwendungssymbol und der Eintrag im Menü.**
///
/// Unter Wayland zeigt die Leiste nicht an, was ein Fenster ihr sagt, sondern
/// was im `.desktop`-Eintrag steht, den sie über die Anwendungskennung
/// findet. Ohne Eintrag gibt es kein Symbol — deshalb fehlte es, obwohl das
/// Bild längst dalag.
///
/// Auf Apple erledigt das Xcode, hier gibt es kein Paket, in das etwas
/// hineinginge. Also legt die App beides selbst ab, in **ihrem eigenen**
/// Verzeichnis unter `~/.local/share` — nichts davon berührt das System.
enum Zeichenwerk {

    static let kennung = "de.paulherter.swiftly"

    /// Der Ort der mitgelieferten Bilder, hergeleitet aus dem Binärpfad:
    /// `Linux/.build/<Ziel>/debug/SwiftlyLinux` → vier Ebenen hinauf ist
    /// `Linux/`, und dort liegt `Ressourcen`.
    private static var mitgeliefert: URL? {
        guard let selbst = try? FileManager.default
            .destinationOfSymbolicLink(atPath: "/proc/self/exe") else { return nil }
        var baum = URL(fileURLWithPath: selbst)
        for _ in 0..<4 { baum.deleteLastPathComponent() }
        let ordner = baum.appendingPathComponent("Ressourcen/icons")
        return FileManager.default.fileExists(atPath: ordner.path) ? ordner : nil
    }

    /// Legt Symbol und Eintrag ab, wenn sie fehlen oder älter sind.
    ///
    /// **Still im Fehlerfall.** Ein fehlendes Symbol ist ein Schönheitsfehler;
    /// die App deshalb anzuhalten oder zu meckern wäre schlimmer als das
    /// Symbol.
    static func einrichten() {
        let dm = FileManager.default
        guard let quelle = mitgeliefert else { return }
        let heim = URL(fileURLWithPath: NSHomeDirectory())
        let ziel = heim.appendingPathComponent(".local/share/icons/hicolor")

        for groesse in ["32x32", "64x64", "128x128", "256x256", "512x512"] {
            let von = quelle.appendingPathComponent("hicolor/\(groesse)/apps/\(kennung).png")
            let nach = ziel.appendingPathComponent("\(groesse)/apps/\(kennung).png")
            guard dm.fileExists(atPath: von.path) else { continue }
            try? dm.createDirectory(at: nach.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if let neu = try? Data(contentsOf: von),
               (try? Data(contentsOf: nach)) != neu {
                try? neu.write(to: nach)
            }
        }

        let eintrag = """
        [Desktop Entry]
        Type=Application
        Name=Swiftly
        GenericName=for Jellyfin
        Comment=Jellyfin-Client, der niemals transkodiert
        Exec=\(realpath("/proc/self/exe"))
        Icon=\(kennung)
        StartupWMClass=\(kennung)
        Categories=AudioVideo;Video;Player;
        Terminal=false

        """
        let wo = heim.appendingPathComponent(".local/share/applications/\(kennung).desktop")
        try? dm.createDirectory(at: wo.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if (try? String(contentsOf: wo, encoding: .utf8)) != eintrag {
            try? eintrag.write(to: wo, atomically: true, encoding: .utf8)
        }

        // Damit GTK das Bild auch ohne Neustart der Sitzung findet.
        if let anzeige = gdk_display_get_default() {
            gtk_icon_theme_add_search_path(gtk_icon_theme_get_for_display(anzeige),
                                           quelle.path)
        }
    }

    private static func realpath(_ pfad: String) -> String {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: pfad)) ?? pfad
    }
}
