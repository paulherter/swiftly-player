#if os(Linux)
import Foundation
import Glibc

/// **Removes leftovers of an older version before startup.**
///
/// Two cases made the old app appear after an update:
///
/// 1. **It was still running.** The app is a D-Bus singleton: a second copy
///    brings the first to the front instead of opening a window. If the app was
///    open or in the background during the update, launching it again returned
///    the **old process**, which still runs the replaced program from memory.
/// 2. **A second copy under `~/.local`.** Built from source, it comes before
///    `/usr/bin` in the search path and has its own menu entry.
///
/// Settings, accounts and servers live under `~/.config/swiftly` and are never
/// touched.
enum OldRun {

    private static let program = "swiftly-jellyfin"
    private static let identifier = "de.paulherter.swiftly"

    /// Runs before `g_application_run`. Returns if startup may proceed; otherwise
    /// calls `execv` and never returns.
    static func cleanUp() {
        localCopyRemove()
        ownCopyReplace()
        endStaleRunners()
    }

    // MARK: Running old copies

    /// Terminates other processes of this app that no longer match what is on
    /// disk: their program was replaced (`(deleted)`) or they run from a different
    /// path. A healthy second start of the same file is left alone; it brings the
    /// first copy to the front.
    private static func endStaleRunners() {
        guard let ich = exePath(from: getpid()) else { return }
        let own = ich.hasSuffix(" (deleted)") ? String(ich.dropLast(10)) : ich
        var victim: [pid_t] = []
        for entryRecord in (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? [] {
            guard let pid = pid_t(entryRecord), pid != getpid(),
                  let path = exePath(from: pid) else { continue }
            let deleted = path.hasSuffix(" (deleted)")
            let clean = deleted ? String(path.dropLast(10)) : path
            guard (clean as NSString).lastPathComponent == program else { continue }
            if deleted || clean != own { victim.append(pid) }
        }
        guard !victim.isEmpty else { return }
        AppLog.writeOut("[Start] \(victim.count) veraltete Kopie(n) laufen noch, beende sie: \(victim)")
        for pid in victim { kill(pid, SIGTERM) }
        // Up to four seconds to shut down, then forced. D-Bus only releases the name
        // once the process is gone, and only then does this process become the first
        // copy instead of the second.
        for _ in 0..<40 where victim.contains(where: { kill($0, 0) == 0 }) {
            usleep(100_000)
        }
        for pid in victim where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        usleep(150_000)
    }

    private static func exePath(from pid: pid_t) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe")
    }

    // MARK: Copy under ~/.local

    private static let clearMark = "SWIFTLY_ALTKOPIE_WEG"

    /// Second half of the replacement: the package version cleans up what the
    /// superseded copy left in the home directory.
    private static func localCopyRemove() {
        guard getenv(clearMark) != nil else { return }
        unsetenv(clearMark)
        let local = "\(NSHomeDirectory())/.local"
        let fm = FileManager.default
        for path in ["\(local)/share/\(program)", "\(local)/bin/\(program)",
                     "\(local)/share/applications/\(identifier).desktop",
                     "\(local)/share/metainfo/\(identifier).metainfo.xml"] {
            try? fm.removeItem(atPath: path)
        }
        for grad in [32, 64, 128, 256, 512] {
            try? fm.removeItem(atPath: "\(local)/share/icons/hicolor/\(grad)x\(grad)/apps/\(identifier).png")
        }
        AppLog.writeOut("[Start] Alte Kopie unter ~/.local entfernt")
    }

    /// If this file runs from `~/.local` and a package in `/usr/lib` that is **not
    /// older** exists, the home copy is removed and the package is started. A newer,
    /// self-built version stays: whoever built it wants it.
    private static func ownCopyReplace() {
        guard let ich = exePath(from: getpid()) else { return }
        let home = NSHomeDirectory()
        let localOnly = "\(home)/.local/share/\(program)/"
        guard ich.hasPrefix(localOnly) else { return }
        let pack = "/usr/lib/\(program)/\(program)"
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: pack),
              let a = try? fm.attributesOfItem(atPath: pack)[.modificationDate] as? Date,
              let b = try? fm.attributesOfItem(atPath: ich)[.modificationDate] as? Date,
              a >= b else {
            if fm.isExecutableFile(atPath: pack) {
                AppLog.writeOut("[Start] Eine Paketfassung liegt unter /usr/lib, diese Kopie unter ~/.local ist aber neuer — sie bleibt")
            }
            return
        }
        AppLog.writeOut("[Start] Alte Kopie unter ~/.local gefunden, starte das Paket aus /usr/lib")
        // Cleanup only happens from the package version: if `execv` failed, this copy
        // would otherwise lose the resources next to its binary.
        setenv(clearMark, "1", 1)
        // Same arguments, different program. If `execv` fails, this copy keeps running;
        // at least it is still intact.
        var arguments: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
        arguments[0] = strdup(pack)
        arguments.append(nil)
        execv(pack, arguments)
    }
}
#endif
