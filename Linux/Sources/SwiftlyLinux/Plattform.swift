import Foundation

/// **Was auf jeder Plattform anders heisst, aber dasselbe bedeutet.**
///
/// Die Oberfläche liegt genau einmal im Repo und wird von Linux und Windows
/// gemeinsam gebaut. Damit das trägt, darf kein Pfad und kein Ordnername
/// mitten im Code stehen — sonst wandert die erste Abweichung in eine
/// `#if`-Verzweigung, die zweite in die nächste, und irgendwann laufen die
/// Fassungen auseinander, ohne dass es jemand merkt. Alles, was sich
/// unterscheidet, steht deshalb hier.
enum Plattform {

    /// Der Pfad des laufenden Programms.
    ///
    /// **Auf Linux über `/proc/self/exe`**, nicht über `Bundle.main`: der
    /// Bündelpfad zeigt bei einem SwiftPM-Bau auf das Bauverzeichnis und
    /// nicht auf die Datei, und aus ihr wird der Ort der mitgelieferten
    /// Mittel hergeleitet. Auf Windows gibt es den symbolischen Verweis
    /// nicht; dort liefert Foundation den Pfad direkt.
    static var programmpfad: String? {
        #if os(Linux)
        return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        #else
        return Bundle.main.executablePath ?? CommandLine.arguments.first
        #endif
    }

    /// Der Ordner mit den mitgelieferten Mitteln — Symbol und Startanimation.
    ///
    /// Hergeleitet aus dem Binärpfad: `<Plattform>/.build/<Ziel>/debug/<Name>`
    /// liegt vier Ebenen unter dem Plattformverzeichnis, und dort liegt
    /// `Ressourcen`. Im installierten Zustand liegt der Ordner direkt daneben;
    /// beides wird geprüft, damit derselbe Code für den Bau und für die
    /// Installation gilt.
    static func mitgeliefert(_ name: String) -> String? {
        guard let selbst = programmpfad else { return nil }
        let dm = FileManager.default
        var kandidaten: [URL] = []

        var baum = URL(fileURLWithPath: selbst).deletingLastPathComponent()
        kandidaten.append(baum.appendingPathComponent("Ressourcen"))
        for _ in 0..<4 {
            baum.deleteLastPathComponent()
            kandidaten.append(baum.appendingPathComponent("Ressourcen"))
        }

        for k in kandidaten {
            let pfad = k.appendingPathComponent(name).path
            if dm.fileExists(atPath: pfad) { return pfad }
        }
        return nil
    }

    /// Wo die App ihre Einstellungen ablegt.
    ///
    /// Linux folgt der XDG-Festlegung, Windows dem Ort, den das System für
    /// Anwendungsdaten vorsieht — `%APPDATA%`. Beides ist das, was ein Nutzer
    /// der jeweiligen Plattform erwartet, und beides braucht keine Rechte.
    static var einstellungsordner: URL {
        #if os(Windows)
        let basis = ProcessInfo.processInfo.environment["APPDATA"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("AppData/Roaming")
        return basis.appendingPathComponent("Swiftly")
        #else
        let basis = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        return basis.appendingPathComponent("swiftly")
        #endif
    }
}
