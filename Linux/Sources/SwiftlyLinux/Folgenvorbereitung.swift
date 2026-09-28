import CGtk
import Foundation
import JellyfinKit

/// **Die nächste Folge in den letzten Minuten vorbereiten** — Plan holen und
/// den Anfang der Datei einmal anfordern, damit der Wechsel ohne Ladekreis
/// geht. Wann und wie viel, entscheidet ``Vorpuffer`` im Paket; der Ablauf ist
/// wörtlich `Sources/iOS/Folgenvorbereitung.swift`.
///
/// Der Player bleibt einer: kein zweites Medium, kein zweiter libVLC. Beim
/// Wechsel nimmt ``App/wechsleZu(_:ab:)`` den fertigen Plan statt ihn zu
/// holen, und der Server liefert den Anfang aus dem Speicher statt von der
/// Platte.
///
/// **Das Netz fragt GLib**, nicht `NWPathMonitor` (gibt es hier nicht):
/// `g_network_monitor_get_network_metered` — dieselbe Frage, die die
/// Downloads schon stellen (``Downloadverwaltung/imWLAN``). Getaktet heißt
/// bei NetworkManager Mobilfunk oder ein als getaktet markiertes WLAN; das
/// entspricht `isExpensive || isConstrained` auf Apple.
///
/// Lebt auf GTKs Faden; nur Plan und Dateianfang laufen abseits.
final class Folgenvorbereitung: @unchecked Sendable {
    private struct Fertig {
        let id: String
        let plan: PlaybackPlan
        let wann: Date
    }

    private var fertig: Fertig?
    /// Die Folge, für die gerade vorbereitet wird oder wurde — einmal je
    /// Folge, auch wenn es scheitert.
    private var angefangen: String?
    private var aufgabe: Task<Void, Never>?
    /// Zählt jedes ``vergessen()`` — ein Plan, der danach ankommt, gehört
    /// zu einem Stand, den es nicht mehr gibt.
    private var runde = 0

    /// Verbunden und nicht getaktet.
    var netzGuenstig: Bool {
        guard let wacht = g_network_monitor_get_default() else { return true }
        return g_network_monitor_get_network_available(wacht) != 0
            && g_network_monitor_get_network_metered(wacht) == 0
    }

    /// Einmal je Folge anstoßen; jeder weitere Aufruf für dieselbe tut nichts.
    func vorbereiten(_ folge: Item, planen: @escaping @Sendable () async -> PlaybackPlan?) {
        guard angefangen != folge.id else { return }
        angefangen = folge.id
        fertig = nil
        aufgabe?.cancel()
        let meine = runde
        aufgabe = Task.detached { [self] in
            let beginn = Date()
            guard let plan = await planen(), !Task.isCancelled else { return }
            aufHauptfaden {
                guard self.runde == meine, self.angefangen == folge.id else { return }
                self.fertig = Fertig(id: folge.id, plan: plan, wann: Date())
            }
            Protokoll.schreib("[Vorpuffer] Plan bereit nach \(Self.ms(seit: beginn)) ms · \(plan.method.wireName)")
            fflush(nil)
            guard Vorpuffer.anfangLaden(adresse: plan.url, methode: plan.method) else { return }
            await Self.anfangLaden(plan.url)
        }
    }

    /// Der fertige Plan für diese Folge, falls es einen gibt und er noch
    /// frisch ist. Einmal genommen, ist er verbraucht.
    func nimm(_ id: String) -> PlaybackPlan? {
        defer { fertig = nil }
        guard let fertig, fertig.id == id,
              Vorpuffer.frisch(vorbereitet: fertig.wann, jetzt: Date()) else { return nil }
        return fertig.plan
    }

    /// Alles vergessen — nach einer Qualitätswahl, die den Plan ändert, und
    /// beim Schließen des Players.
    func vergessen() {
        aufgabe?.cancel()
        aufgabe = nil
        fertig = nil
        angefangen = nil
        runde += 1
    }

    /// Den Anfang der Datei einmal anfordern — ``Vorpuffer/anfangAnfordern(_:)``
    /// im Paket, mit den eigenen Köpfen des Servers. Die Bytes selbst werden
    /// verworfen; es geht darum, dass der Server sie danach im Speicher hat.
    private static func anfangLaden(_ adresse: URL) async {
        let beginn = Date()
        do {
            let anzahl = try await Vorpuffer.anfangAnfordern(adresse)
            Protokoll.schreib("[Vorpuffer] Anfang vorgeladen: \(anzahl / 1024) KB in \(ms(seit: beginn)) ms")
        } catch {
            Protokoll.schreib("[Vorpuffer] Anfang nicht geladen: \(error.localizedDescription)")
        }
        fflush(nil)
    }

    private static func ms(seit: Date) -> Int { Int(Date().timeIntervalSince(seit) * 1000) }
}
