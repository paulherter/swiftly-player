import Foundation

/// **Zwischen der Wiedergabe und Trakt — und so gebaut, dass Trakt die
/// Wiedergabe nie aufhält.**
///
/// Die Plattformen rufen ``melden(_:)`` an genau den Stellen, an denen sie
/// auch Jellyfin Bescheid geben: Start, Pause und Weiter, Sprung, Ende. Der
/// Aufruf kehrt sofort zurück; gesendet wird in einer eigenen Reihe.
///
/// **Eine Reihe, keine einzelnen Aufgaben.** Jede Meldung als eigene
/// `Task` abzusetzen hieße, dass „Pause" vor „Start" ankommen kann — die
/// Reihenfolge von Aufgaben ist nicht zugesichert. Ein `AsyncStream` hält
/// sie ein, und ein einziger Abnehmer arbeitet sie der Reihe nach ab.
///
/// **Fehler bleiben hier.** Kein Wurf verlässt diesen Typ: eine Meldung an
/// Trakt, die nicht durchkommt, wird ins Protokoll geschrieben und
/// vergessen. Den Stand des Nutzers hält Jellyfin; Trakt ist die Zugabe.
///
/// Was Trakt daraus macht, entscheidet Trakt: ein Stopp ab 80 % zählt als
/// gesehen, darunter als angehalten. Deshalb gibt es hier keine eigene
/// 80-%-Regel und kein `/sync/history` — beides trüge denselben Titel ein
/// zweites Mal ein.
public final class Traktmelder: Sendable {

    public enum Ereignis: Sendable {
        /// Ein Titel beginnt. `ziel` wird erst in der Reihe aufgelöst — das
        /// kostet zwei Anfragen an den eigenen Server, und die sollen weder
        /// den Player noch den Hauptlauf aufhalten.
        case start(titelID: String, ziel: @Sendable () async -> TraktZiel?,
                   stelle: Double, dauer: Double)
        case laufzustand(laeuft: Bool, stelle: Double)
        case sprung(stelle: Double)
        case stopp(titelID: String, stelle: Double)
    }

    private enum Eintrag: Sendable {
        case ereignis(Ereignis)
        case token(TraktToken?, kennung: String?)
        case marke(@Sendable () -> Void)
    }

    private let eingang: AsyncStream<Eintrag>.Continuation

    /// - Parameters:
    ///   - geaendert: ein Token wurde erneuert (neuer Wert) oder ist tot
    ///     (`nil`). Mit der Kennung, die beim Setzen mitkam — damit ein
    ///     erneuerter Token nach einem Kontowechsel nicht beim falschen Konto
    ///     landet.
    ///   - protokoll: eine Zeile fürs Protokoll, ohne Token darin.
    ///   - jetzt: nur für die Tests.
    public init(client: TraktClient,
                geaendert: @escaping @Sendable (TraktToken?, String?) -> Void,
                protokoll: @escaping @Sendable (String) -> Void,
                jetzt: @escaping @Sendable () -> Date = { Date() }) {
        let (strom, eingang) = AsyncStream.makeStream(of: Eintrag.self)
        self.eingang = eingang
        let arbeiter = Arbeiter(client: client, geaendert: geaendert,
                                protokoll: protokoll, jetzt: jetzt)
        Task {
            for await eintrag in strom {
                switch eintrag {
                case let .ereignis(e):         await arbeiter.verarbeiten(e)
                case let .token(t, kennung):   await arbeiter.setzen(t, kennung: kennung)
                case let .marke(fertig):       fertig()
                }
            }
        }
    }

    deinit { eingang.finish() }

    public func melden(_ ereignis: Ereignis) {
        eingang.yield(.ereignis(ereignis))
    }

    /// Der Token des Kontos, das gerade angemeldet ist, oder `nil`.
    /// Geht durch dieselbe Reihe — eine Meldung, die vor dem Wechsel kam,
    /// geht noch mit dem alten Token hinaus.
    public func tokenSetzen(_ token: TraktToken?, kennung: String?) {
        eingang.yield(.token(token, kennung: kennung))
    }

    /// Kehrt zurück, wenn alles davor abgearbeitet ist. Für die Tests.
    public func abgearbeitet() async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            eingang.yield(.marke { k.resume() })
        }
    }

    // MARK: - Der Abnehmer

    private actor Arbeiter {
        let client: TraktClient
        let geaendert: @Sendable (TraktToken?, String?) -> Void
        let protokoll: @Sendable (String) -> Void
        let jetzt: @Sendable () -> Date

        var token: TraktToken?
        var kennung: String?
        /// Was gerade läuft — nur, wenn es sich Trakt zuordnen ließ.
        var aktuell: (titelID: String, ziel: TraktZiel, dauer: Double)?
        var laeuft = false
        var zuletztGesendet = Date.distantPast
        /// Nach einem 429 bis hierhin still sein.
        var gesperrtBis = Date.distantPast

        /// **Ein Sprung meldet sich höchstens alle 30 Sekunden.** Wer am
        /// Regler zieht, erzeugt Dutzende Sprünge, und Trakt beantwortet
        /// eine Flut zum selben Titel mit 409 oder 429.
        static let sprungabstand: TimeInterval = 30

        init(client: TraktClient, geaendert: @escaping @Sendable (TraktToken?, String?) -> Void,
             protokoll: @escaping @Sendable (String) -> Void, jetzt: @escaping @Sendable () -> Date) {
            self.client = client
            self.geaendert = geaendert
            self.protokoll = protokoll
            self.jetzt = jetzt
        }

        func setzen(_ neu: TraktToken?, kennung: String?) {
            token = neu
            self.kennung = kennung
            if neu == nil { aktuell = nil }
        }

        func verarbeiten(_ e: Ereignis) async {
            switch e {
            case let .start(titelID, aufloesen, stelle, dauer):
                aktuell = nil
                // Nicht verbunden: nichts auflösen, nichts fragen.
                guard token != nil else { return }
                guard dauer > 0 else {
                    protokoll("ohne Laufzeit, nicht gemeldet \(titelID)")
                    return
                }
                guard let ziel = await aufloesen() else {
                    protokoll("keine IMDb/TMDB/TVDB-Kennung, nicht gemeldet \(titelID)")
                    return
                }
                aktuell = (titelID, ziel, dauer)
                laeuft = true
                await senden(.start, stelle: stelle)
            case let .laufzustand(neu, stelle):
                guard aktuell != nil, neu != laeuft else { return }
                laeuft = neu
                await senden(neu ? .start : .pause, stelle: stelle)
            case let .sprung(stelle):
                guard aktuell != nil,
                      jetzt().timeIntervalSince(zuletztGesendet) >= Self.sprungabstand else { return }
                await senden(laeuft ? .start : .pause, stelle: stelle)
            case let .stopp(titelID, stelle):
                // Nur den Titel beenden, der hier läuft — beim Folgenwechsel
                // soll ein später Stopp nicht die neue Folge treffen.
                guard let a = aktuell, a.titelID == titelID else { return }
                await senden(.stop, stelle: stelle)
                aktuell = nil
                laeuft = false
            }
        }

        private func senden(_ schritt: TraktClient.Schritt, stelle: Double) async {
            guard let aktuell, var t = token else { return }
            let jetzt = jetzt()
            guard jetzt >= gesperrtBis else {
                protokoll("\(schritt.rawValue) übergangen, Trakt bremst noch")
                return
            }
            zuletztGesendet = jetzt
            if t.erneuernFaellig(jetzt: jetzt) {
                guard let neu = await erneuern(t) else {
                    if token == nil { return }
                    // Vorübergehend gescheitert: mit dem alten weiter, der
                    // gilt noch bis zu einer Stunde.
                    return await versuchen(schritt, aktuell, stelle, t, nochmal: true)
                }
                t = neu
            }
            await versuchen(schritt, aktuell, stelle, t, nochmal: true)
        }

        private func versuchen(_ schritt: TraktClient.Schritt,
                               _ a: (titelID: String, ziel: TraktZiel, dauer: Double),
                               _ stelle: Double, _ t: TraktToken, nochmal: Bool) async {
            let fortschritt = stelle / a.dauer * 100
            do {
                try await client.melden(schritt, ziel: a.ziel, fortschritt: fortschritt, token: t.zugriff)
                protokoll("\(schritt.rawValue) \(Int(fortschritt)) % \(a.titelID)")
            } catch TraktFehler.status(401) where nochmal {
                // Abgelaufen, obwohl die Uhr es anders sah — einmal erneuern
                // und nachschicken.
                guard let neu = await erneuern(t) else { return }
                await versuchen(schritt, a, stelle, neu, nochmal: false)
            } catch let TraktFehler.ratenlimit(nach) {
                gesperrtBis = jetzt().addingTimeInterval(nach ?? 60)
                protokoll("\(schritt.rawValue): Trakt bremst (429), \(Int(nach ?? 60)) s Pause")
            } catch {
                protokoll("\(schritt.rawValue) nicht durch: \(error)")
            }
        }

        /// `nil` heißt: nicht erneuert. Ist der Zugang tot, ist danach auch
        /// ``token`` `nil`, und die App erfährt es über `geaendert`.
        private func erneuern(_ t: TraktToken) async -> TraktToken? {
            do {
                let neu = try await client.erneuern(t)
                token = neu
                geaendert(neu, kennung)
                protokoll("Token erneuert")
                return neu
            } catch TraktFehler.abgemeldet {
                token = nil
                aktuell = nil
                geaendert(nil, kennung)
                protokoll("Zugang abgelaufen, getrennt")
                return nil
            } catch {
                protokoll("Erneuern nicht durch: \(error)")
                return nil
            }
        }
    }
}
