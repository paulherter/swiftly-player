import Foundation

/// Meldungen an den Server — **abgesetzt, nicht abgewartet** (Audit
/// 16.09.2026, Teil 1 H2, M9, N1; Teil 3 #5 und #13).
///
/// Die Taktschleife rief `await reportProgress(…)` und wartete auf die
/// Antwort. So lange rückte die Zeitleiste nicht vor, der Sprungriegel fiel
/// nicht, und die nächste Folge schaltete nicht weiter. Ohne Netz waren das
/// bis zu 20 Sekunden (`Netzsitzung`), beim Start mit den Fähigkeiten davor
/// bis zu 40.
///
/// **Was hier zugesagt wird:**
///
/// 1. `melden` kehrt sofort zurück. Niemand wartet, der nicht ausdrücklich
///    `meldenUndWarten` sagt — das tut nur das Ende, weil danach die Seiten
///    neu laden (d8492ca).
/// 2. **Eine Reihe für alle Meldungen**, abgeschickt in der Reihenfolge des
///    Einreihens. Start → Fortschritt → Stopp bleibt so, auch wenn der Start
///    langsam ist; ebenso Stopp der alten Folge → Start der neuen.
/// 3. **Fortschritt wird zusammengefasst.** Liegt für dieselbe Sitzung noch
///    ein ungesendeter Fortschritt als letzter Eintrag, fällt er weg und der
///    neue kommt ans Ende. Ohne Netz staut sich also nichts: es liegt höchstens
///    ein Fortschritt je Sitzung da. Ein Stopp nimmt den ungesendeten
///    Fortschritt seiner Sitzung mit — er trägt die Stelle selbst.
/// 4. **Jede Meldung hat eine Frist.** Danach wird sie abgebrochen und die
///    nächste geht. Ein Fehler hält nichts auf.
/// 5. **Die Stoppsperre sitzt hier**, nicht daneben: Stopp genau einmal je
///    PlaySession, Fortschritt danach verworfen, Start und gescheiterter
///    Stopp geben frei. Geprüft wird beim Einreihen — so gilt die Sperre schon
///    für den Stopp, der noch in der Reihe steht.
///
/// **Nicht an `@MainActor` gebunden**, aus demselben Grund wie
/// `Folgenwechsel`: Android ruft über JNI ohne Hauptwarteschlange. Der
/// Zustand liegt hinter einem Schloss, gesendet wird auf dem allgemeinen
/// Ausführer. Was gesendet wird, weiß der Aufrufer — die Reihe kennt nur Art,
/// Sitzung und eine Nutzlast.
public final class Meldewarteschlange<Nutzlast: Sendable>: @unchecked Sendable {

    public enum Art: Sendable, Equatable {
        case start
        case fortschritt(pausiert: Bool)
        case stopp
    }

    public struct Meldung: Sendable {
        public let art: Art
        /// `Stoppsperre.schluessel(itemID:playSessionID:)`.
        public let schluessel: String
        public let nutzlast: Nutzlast

        public init(art: Art, schluessel: String, nutzlast: Nutzlast) {
            self.art = art
            self.schluessel = schluessel
            self.nutzlast = nutzlast
        }
    }

    public enum Ergebnis: Sendable, Equatable {
        case gesendet
        case gescheitert
        case zeitUeberschritten
        /// Nie abgeschickt: Fortschritt nach dem Stopp, doppelter Stopp, oder
        /// ein Fortschritt, den der Stopp seiner Sitzung mitgenommen hat.
        case verworfen
    }

    /// Sechs Sekunden: ein erreichbarer Server antwortet in Bruchteilen davon.
    /// Wer länger braucht, ist für diese Meldung nicht erreichbar — die
    /// nächste versucht es wieder, und das Ende geht in die Nachmeldung.
    public static var vorgabeFrist: Duration { .seconds(6) }

    private final class Eintrag {
        let meldung: Meldung
        var wartende: [CheckedContinuation<Ergebnis, Never>]
        init(_ meldung: Meldung, wartende: [CheckedContinuation<Ergebnis, Never>]) {
            self.meldung = meldung
            self.wartende = wartende
        }
    }

    private let schloss = NSLock()
    private var offen: [Eintrag] = []
    private var arbeitet = false
    private let sperre = Stoppsperre()
    private let frist: Duration
    private let senden: @Sendable (Meldung) async throws -> Void

    public init(frist: Duration = vorgabeFrist,
                senden: @escaping @Sendable (Meldung) async throws -> Void) {
        self.frist = frist
        self.senden = senden
    }

    /// Einreihen und sofort zurück. `false`: verworfen (siehe `Ergebnis`).
    @discardableResult
    public func melden(_ meldung: Meldung) -> Bool {
        einreihen(meldung, wartend: nil)
    }

    /// Einreihen und warten, bis genau diese Meldung durch ist — oder ihre
    /// Frist abgelaufen. Wird ein wartender Fortschritt von einem neueren
    /// ersetzt, gilt dessen Ergebnis.
    public func meldenUndWarten(_ meldung: Meldung) async -> Ergebnis {
        await withCheckedContinuation { fortsetzung in
            if !einreihen(meldung, wartend: fortsetzung) {
                fortsetzung.resume(returning: .verworfen)
            }
        }
    }

    /// Darf für diese Sitzung noch Fortschritt gemeldet werden?
    public func fortschrittErlaubt(_ schluessel: String) -> Bool {
        sperre.fortschrittErlaubt(schluessel)
    }

    // MARK: Innen

    /// Gibt `false` zurück, ohne `wartend` behalten zu haben.
    private func einreihen(_ meldung: Meldung,
                           wartend: CheckedContinuation<Ergebnis, Never>?) -> Bool {
        var mitgenommen: [CheckedContinuation<Ergebnis, Never>] = []
        let (angenommen, anstossen) = mitSchloss { () -> (Bool, Bool) in
            var wartende = wartend.map { [$0] } ?? []
            let letzter = offen.lastIndex { $0.meldung.schluessel == meldung.schluessel }
            let letzterIstFortschritt = letzter.map {
                if case .fortschritt = offen[$0].meldung.art { return true }
                return false
            } ?? false

            switch meldung.art {
            case .start:
                sperre.gestartet(meldung.schluessel)
            case .fortschritt:
                guard sperre.fortschrittErlaubt(meldung.schluessel) else { return (false, false) }
                if letzterIstFortschritt, let letzter {
                    wartende = offen[letzter].wartende + wartende
                    offen.remove(at: letzter)
                }
            case .stopp:
                guard sperre.stoppAnnehmen(meldung.schluessel) else { return (false, false) }
                if letzterIstFortschritt, let letzter {
                    mitgenommen = offen[letzter].wartende
                    offen.remove(at: letzter)
                }
            }
            offen.append(Eintrag(meldung, wartende: wartende))
            guard !arbeitet else { return (true, false) }
            arbeitet = true
            return (true, true)
        }
        for fortsetzung in mitgenommen { fortsetzung.resume(returning: .verworfen) }
        if anstossen {
            Task { await self.abarbeiten() }
        }
        return angenommen
    }

    private func abarbeiten() async {
        while let eintrag = naechster() {
            let ergebnis = await mitFrist(eintrag.meldung)
            if ergebnis != .gesendet, eintrag.meldung.art == .stopp {
                // Freigeben, damit ein späterer Stopp es noch einmal versucht.
                sperre.stoppGescheitert(eintrag.meldung.schluessel)
            }
            for fortsetzung in eintrag.wartende { fortsetzung.resume(returning: ergebnis) }
        }
    }

    private func naechster() -> Eintrag? {
        mitSchloss {
            guard !offen.isEmpty else {
                arbeitet = false
                return nil
            }
            return offen.removeFirst()
        }
    }

    /// Senden gegen die Frist. **Unstrukturiert mit Absicht:** eine
    /// Aufgabengruppe wartet am Ende auf alle Kinder — hielte sich das Senden
    /// nicht an den Abbruch, stünde die Reihe doch.
    private func mitFrist(_ meldung: Meldung) async -> Ergebnis {
        let einmal = Einmal()
        let senden = self.senden
        let frist = self.frist
        let arbeit = Task {
            do {
                try await senden(meldung)
                einmal.geben(.gesendet)
            } catch {
                einmal.geben(.gescheitert)
            }
        }
        let wecker = Task {
            do { try await Task.sleep(for: frist) } catch { return }
            if einmal.geben(.zeitUeberschritten) { arbeit.cancel() }
        }
        let ergebnis = await einmal.warten()
        wecker.cancel()
        return ergebnis
    }

    private func mitSchloss<T>(_ tun: () -> T) -> T {
        schloss.lock(); defer { schloss.unlock() }
        return tun()
    }

    /// Das erste Ergebnis gilt — Antwort oder Frist.
    private final class Einmal: @unchecked Sendable {
        private let schloss = NSLock()
        private var ergebnis: Ergebnis?
        private var fortsetzung: CheckedContinuation<Ergebnis, Never>?

        @discardableResult
        func geben(_ neu: Ergebnis) -> Bool {
            schloss.lock()
            guard ergebnis == nil else { schloss.unlock(); return false }
            ergebnis = neu
            let wartend = fortsetzung
            fortsetzung = nil
            schloss.unlock()
            wartend?.resume(returning: neu)
            return true
        }

        func warten() async -> Ergebnis {
            await withCheckedContinuation { neu in
                schloss.lock()
                if let ergebnis {
                    schloss.unlock()
                    neu.resume(returning: ergebnis)
                } else {
                    fortsetzung = neu
                    schloss.unlock()
                }
            }
        }
    }
}
