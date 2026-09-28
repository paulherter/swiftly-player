import Foundation
import JellyfinKit
import Network

/// **Die nächste Folge in den letzten Minuten vorbereiten** — Plan holen und
/// den Anfang der Datei einmal anfordern, damit der Wechsel ohne Ladekreis
/// geht. Wann und wie viel, entscheidet ``Vorpuffer`` im Paket.
///
/// Der Player bleibt einer: kein zweites Medium, kein zweiter VLC. Beim
/// Wechsel nimmt `zurNaechstenFolge` den fertigen Plan statt ihn zu holen,
/// und der Server liefert den Anfang aus dem Speicher statt von der Platte.
@MainActor
final class Folgenvorbereitung {
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

    /// WLAN oder Kabel, ohne Datensparmodus. Vom Netzwächter nachgeführt.
    private(set) var netzGuenstig = false
    private let wache = NWPathMonitor()

    init() {
        wache.pathUpdateHandler = { [weak self] pfad in
            let guenstig = pfad.status == .satisfied && !pfad.isExpensive && !pfad.isConstrained
            Task { @MainActor in self?.netzGuenstig = guenstig }
        }
        wache.start(queue: DispatchQueue(label: "de.paulherter.swiftly.vorpuffer"))
    }

    deinit { wache.cancel() }

    /// Einmal je Folge anstoßen; jeder weitere Aufruf für dieselbe tut nichts.
    func vorbereiten(_ folge: Item, planen: @escaping () async -> PlaybackPlan?) {
        guard angefangen != folge.id else { return }
        angefangen = folge.id
        fertig = nil
        aufgabe?.cancel()
        aufgabe = Task { [weak self] in
            let beginn = Date()
            guard let plan = await planen(), !Task.isCancelled else { return }
            self?.fertig = Fertig(id: folge.id, plan: plan, wann: Date())
            Protokoll.schreib("[Vorpuffer] Plan bereit nach \(Self.ms(seit: beginn)) ms"
                + " · \(plan.method.wireName)")
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

    /// Alles vergessen — etwa nach einer Qualitätswahl, die den Plan ändert.
    func vergessen() {
        aufgabe?.cancel()
        aufgabe = nil
        fertig = nil
        angefangen = nil
    }

    /// Den Anfang der Datei einmal anfordern (`Vorpuffer.anfangAnfordern`,
    /// mit den eigenen Köpfen des Servers). Die Bytes selbst werden verworfen
    /// — es geht darum, dass der Server sie danach im Speicher hat.
    private static func anfangLaden(_ adresse: URL) async {
        let beginn = Date()
        do {
            let bytes = try await Vorpuffer.anfangAnfordern(adresse)
            Protokoll.schreib("[Vorpuffer] Anfang vorgeladen: \(bytes / 1024) KB"
                + " in \(ms(seit: beginn)) ms")
        } catch {
            Protokoll.schreib("[Vorpuffer] Anfang nicht geladen: \(error.localizedDescription)")
        }
    }

    private static func ms(seit: Date) -> Int { Int(Date().timeIntervalSince(seit) * 1000) }
}
