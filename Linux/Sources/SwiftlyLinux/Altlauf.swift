#if os(Linux)
import Foundation
import Glibc

/// **Räumt vor dem Start weg, was von einer älteren Fassung noch da ist.**
///
/// Zwei Wege führten dazu, dass nach einem Update die alte App erschien:
///
/// 1. **Sie lief noch.** Die App ist über D-Bus einmalig: eine zweite Kopie
///    holt die erste nach vorn, statt ein Fenster zu öffnen. Wer beim
///    Aktualisieren die App offen oder im Hintergrund hatte, tippte danach
///    auf das Symbol und bekam den **alten Prozess** — im Speicher steht noch
///    das ersetzte Programm. Erst ein Neustart über die Konsole half
///    (Nutzer auf CachyOS, 01.10.2026).
/// 2. **Eine zweite Kopie unter `~/.local`.** Aus der Quelle gebaut, steht sie
///    im Suchpfad vor `/usr/bin` und hat einen eigenen Menüeintrag
///    (14.09.2026: pacman hatte 1.0.2, gestartet wurde die 1.0.0).
///
/// Einstellungen, Konten und Server liegen unter `~/.config/swiftly` und
/// werden nirgends angefasst.
enum Altlauf {

    private static let programm = "swiftly-jellyfin"
    private static let kennung = "de.paulherter.swiftly"

    /// Vor `g_application_run`. Kehrt zurück, wenn gestartet werden darf; ruft
    /// sonst `execv` und kehrt nie zurück.
    static func aufraeumen() {
        lokaleKopieEntfernen()
        eigeneKopieAbloesen()
        veralteteLaeuferBeenden()
    }

    // MARK: Laufende Altkopien

    /// Beendet andere Prozesse dieser App, die **nicht** mehr zu dem passen,
    /// was auf der Platte liegt: ihr Programm wurde ersetzt (`(deleted)`) oder
    /// sie laufen aus einem anderen Pfad. Ein gesunder Zweitstart derselben
    /// Datei bleibt, wie er ist — der holt die erste Kopie nach vorn.
    private static func veralteteLaeuferBeenden() {
        guard let ich = exePfad(von: getpid()) else { return }
        let eigener = ich.hasSuffix(" (deleted)") ? String(ich.dropLast(10)) : ich
        var opfer: [pid_t] = []
        for eintrag in (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? [] {
            guard let pid = pid_t(eintrag), pid != getpid(),
                  let pfad = exePfad(von: pid) else { continue }
            let geloescht = pfad.hasSuffix(" (deleted)")
            let sauber = geloescht ? String(pfad.dropLast(10)) : pfad
            guard (sauber as NSString).lastPathComponent == programm else { continue }
            if geloescht || sauber != eigener { opfer.append(pid) }
        }
        guard !opfer.isEmpty else { return }
        Protokoll.schreib("[Start] \(opfer.count) veraltete Kopie(n) laufen noch, beende sie: \(opfer)")
        for pid in opfer { kill(pid, SIGTERM) }
        // Bis zu vier Sekunden Zeit zum Abräumen, danach hart. Erst wenn der
        // Prozess weg ist, gibt D-Bus den Namen frei, und wir werden die erste
        // Kopie statt der zweiten.
        for _ in 0..<40 where opfer.contains(where: { kill($0, 0) == 0 }) {
            usleep(100_000)
        }
        for pid in opfer where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        usleep(150_000)
    }

    private static func exePfad(von pid: pid_t) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe")
    }

    // MARK: Kopie unter ~/.local

    private static let raeumMarke = "SWIFTLY_ALTKOPIE_WEG"

    /// Zweiter Halbsatz der Ablösung: die Paketfassung räumt, was die
    /// abgelöste Kopie im Home hinterlassen hat.
    private static func lokaleKopieEntfernen() {
        guard getenv(raeumMarke) != nil else { return }
        unsetenv(raeumMarke)
        let local = "\(NSHomeDirectory())/.local"
        let fm = FileManager.default
        for pfad in ["\(local)/share/\(programm)", "\(local)/bin/\(programm)",
                     "\(local)/share/applications/\(kennung).desktop",
                     "\(local)/share/metainfo/\(kennung).metainfo.xml"] {
            try? fm.removeItem(atPath: pfad)
        }
        for grad in [32, 64, 128, 256, 512] {
            try? fm.removeItem(atPath: "\(local)/share/icons/hicolor/\(grad)x\(grad)/apps/\(kennung).png")
        }
        Protokoll.schreib("[Start] Alte Kopie unter ~/.local entfernt")
    }

    /// Läuft diese Datei aus `~/.local` und liegt daneben ein Paket in
    /// `/usr/lib`, das **nicht älter** ist, wird die Kopie im Home entfernt und
    /// das Paket gestartet. Eine neuere, selbst gebaute Fassung bleibt stehen:
    /// wer sie gebaut hat, will sie.
    private static func eigeneKopieAbloesen() {
        guard let ich = exePfad(von: getpid()) else { return }
        let home = NSHomeDirectory()
        let lokal = "\(home)/.local/share/\(programm)/"
        guard ich.hasPrefix(lokal) else { return }
        let paket = "/usr/lib/\(programm)/\(programm)"
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: paket),
              let a = try? fm.attributesOfItem(atPath: paket)[.modificationDate] as? Date,
              let b = try? fm.attributesOfItem(atPath: ich)[.modificationDate] as? Date,
              a >= b else {
            if fm.isExecutableFile(atPath: paket) {
                Protokoll.schreib("[Start] Eine Paketfassung liegt unter /usr/lib, diese Kopie unter ~/.local ist aber neuer — sie bleibt")
            }
            return
        }
        Protokoll.schreib("[Start] Alte Kopie unter ~/.local gefunden, starte das Paket aus /usr/lib")
        // Weggeräumt wird erst von der Paketfassung aus: schlüge `execv` fehl,
        // fehlten dieser Kopie sonst ihre Ressourcen neben dem Programm.
        setenv(raeumMarke, "1", 1)
        // Gleiche Argumente, anderes Programm. Schlägt `execv` fehl, läuft
        // diese Kopie weiter — dann ist sie wenigstens noch ganz.
        var argumente: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
        argumente[0] = strdup(paket)
        argumente.append(nil)
        execv(paket, argumente)
    }
}
#endif
