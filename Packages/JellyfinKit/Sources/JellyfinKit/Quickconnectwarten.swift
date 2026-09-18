import Foundation

/// **Das Warten auf eine Quick-Connect-Freigabe, einmal für alle Plattformen.**
///
/// Stand dreimal verschieden im Code: Apple brach beim ersten Netzfehler ab,
/// Linux zählte jeden Fehler als „noch nicht frei“ und lief nach dem
/// Verlassen weiter, Android (88f7808) hatte die Regel richtig, aber in
/// Kotlin. Die Regel ist die von Android:
///
/// - **Frist an der Uhr**, nicht an gezählten Runden. Beim Eintippen im
///   Browser liegt die App im Hintergrund; zurück in der App stimmt die
///   Restzeit.
/// - **Nach der Rückkehr sofort fragen.** Die Uhr tickt jede Sekunde; ist
///   seit der letzten Nachfrage ein Takt vergangen, wird gefragt — nach dem
///   Aufwachen also gleich beim ersten Tick.
/// - **Ein Netzfehler beendet das Warten nicht** (``Quickconnectstand/gescheitert``).
///   Nur Freigabe, abgelaufener Code (404) oder das Fristende tun es.
/// - **Abbrechen beendet alles.** Wer den Strom nicht mehr liest (Ansicht
///   zu, Task abgebrochen), fragt auch nicht mehr nach — sonst meldet eine
///   späte Freigabe einen plötzlich an.
public enum Quickconnectwarten {

    public enum Ereignis: Sendable, Equatable {
        /// Sekunden bis zum Fristende, einmal je Sekunde.
        case rest(Int)
        /// Der Code ist freigegeben — jetzt `anmeldenMitQuickConnect`.
        case freigegeben
        /// Das Warten ist vorbei, ohne Freigabe. Den Satz liefert
        /// ``Quickconnectfrist/schlusstext(letzte:)``.
        case ende(letzte: Quickconnectstand)
    }

    /// - Parameters:
    ///   - frist, takt, tick: nur für Tests anders als ``Quickconnectfrist``.
    ///   - nachfragen: eine Nachfrage, die nie wirft — in der App
    ///     ``JellyfinClient/quickConnectNachfragen(_:)``.
    public static func ablauf(
        frist: Duration = .seconds(Quickconnectfrist.sekunden),
        takt: Duration = .seconds(Quickconnectfrist.takt),
        tick: Duration = .seconds(1),
        nachfragen: @escaping @Sendable () async -> Quickconnectstand
    ) -> AsyncStream<Ereignis> {
        AsyncStream { strom in
            let aufgabe = Task {
                let uhr = ContinuousClock()
                let ende = uhr.now + frist
                var letzteAbfrage = uhr.now
                var letzte = Quickconnectstand.offen
                strom.yield(.rest(restSekunden(ende - uhr.now)))
                while !Task.isCancelled {
                    try? await Task.sleep(for: tick, clock: uhr)
                    if Task.isCancelled { break }
                    let jetzt = uhr.now
                    let rest = restSekunden(ende - jetzt)
                    guard rest > 0 else {
                        strom.yield(.ende(letzte: letzte == .gescheitert ? .gescheitert : .abgelaufen))
                        break
                    }
                    strom.yield(.rest(rest))
                    guard jetzt - letzteAbfrage >= takt else { continue }
                    letzteAbfrage = jetzt
                    letzte = await nachfragen()
                    if Task.isCancelled { break }
                    if letzte == .freigegeben { strom.yield(.freigegeben); break }
                    if letzte == .abgelaufen { strom.yield(.ende(letzte: .abgelaufen)); break }
                }
                strom.finish()
            }
            strom.onTermination = { _ in aufgabe.cancel() }
        }
    }

    /// Aufgerundet: „0:01“ steht da, bis die Frist wirklich um ist.
    static func restSekunden(_ d: Duration) -> Int {
        let (s, atto) = d.components
        guard s >= 0, s > 0 || atto > 0 else { return 0 }
        return Int(s) + (atto > 0 ? 1 : 0)
    }
}

extension JellyfinClient {
    /// Wartet auf die Freigabe von `vorgang` nach ``Quickconnectwarten``.
    public nonisolated func quickConnectWarten(_ vorgang: Anmeldecode) -> AsyncStream<Quickconnectwarten.Ereignis> {
        Quickconnectwarten.ablauf { await self.quickConnectNachfragen(vorgang) }
    }
}
