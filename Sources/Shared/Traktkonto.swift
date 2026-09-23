import Foundation
import JellyfinKit
import Observation

/// Die Anbindung an Trakt, aus Sicht der Oberfläche.
///
/// **Eine Zugabe, wie Seerr.** Wer nichts verbindet, merkt nichts davon —
/// der Melder schickt ohne Token nichts hinaus und fragt nicht einmal den
/// eigenen Server nach Kennungen. Und ohne die Zugangsdaten der Anwendung
/// (``verfuegbar``) steht in den Einstellungen gar keine Zeile.
///
/// **Je Jellyfin-Konto ein eigener Zugang.** Auf einem Fernseher schauen
/// oft mehrere unter verschiedenen Profilen; was die Kinder sehen, gehört
/// nicht in den Trakt-Verlauf der Eltern. Der Schlüssel ist deshalb
/// `Session.kontoschluessel` — Server plus Benutzer.
///
/// Die Logik — Reihe, Erneuern, 80-%-Regel bei Trakt — steht im Paket
/// (`Traktmelder`, `TraktClient`); hier stehen nur Schlüsselbund, Zustand
/// der Anmeldung und die Aufrufe aus `AppModel`.
@MainActor
@Observable
final class Traktkonto {

    /// `nil`, wenn der Bau keine `Trakt.json` hatte.
    private static let zugang = TraktZugang.ausPaket

    /// Steht Trakt in diesem Bau überhaupt zur Wahl?
    var verfuegbar: Bool { Self.zugang != nil }

    /// Was die Anmeldeseite gerade zeigt.
    enum Anmeldung: Equatable {
        case keine
        case holtCode
        case code(TraktGeraetecode, bis: Date)
        case fehler(String)
    }

    private(set) var anmeldung: Anmeldung = .keine
    private(set) var token: TraktToken?
    var verbunden: Bool { token != nil }
    var benutzer: String? { token?.benutzer }

    @ObservationIgnored private var konto: String?
    @ObservationIgnored private var vorgang: Task<Void, Never>?
    @ObservationIgnored private let client: TraktClient?
    @ObservationIgnored private let melder: Traktmelder?

    init() {
        let client = Self.zugang.map { TraktClient(zugang: $0) }
        self.client = client
        melder = client.map { client in
            Traktmelder(
                client: client,
                geaendert: { neu, kennung in
                    Task { @MainActor in Traktkonto.geteilt?.erneuert(neu, kennung: kennung) }
                },
                protokoll: { zeile in Protokoll.schreib("[Trakt] " + zeile) })
        }
        Self.geteilt = self
    }

    /// Für den Rückruf aus dem Melder — der läuft außerhalb des Hauptlaufs
    /// und darf `self` nicht festhalten. Es gibt genau ein Konto, das an
    /// `AppModel` hängt.
    private static weak var geteilt: Traktkonto?

    // MARK: Konto

    private static func schluessel(_ konto: String) -> String { "trakt|" + konto }

    /// Beim Anmelden, Kontowechsel und Abmelden von Jellyfin.
    func kontoGewechselt(_ neu: String?) {
        guard neu != konto else { return }
        abbrechen()
        konto = neu
        token = neu.flatMap { Keychain.load(key: Self.schluessel($0)) }
            .flatMap { try? JSONDecoder().decode(TraktToken.self, from: $0) }
        melder?.tokenSetzen(token, kennung: neu)
    }

    private func speichern(_ neu: TraktToken?, konto: String) {
        let key = Self.schluessel(konto)
        if let neu, let daten = try? JSONEncoder().encode(neu) {
            do { try Keychain.save(daten, key: key) } catch {
                Protokoll.schreib("[Trakt] Schlüsselbund: \(error)")
            }
        } else {
            Keychain.delete(key: key)
        }
    }

    /// Der Melder hat erneuert oder den Zugang verloren.
    private func erneuert(_ neu: TraktToken?, kennung: String?) {
        guard let kennung else { return }
        speichern(neu, konto: kennung)
        if kennung == konto { token = neu }
    }

    // MARK: Verbinden

    /// Holt einen Code und wartet, bis er bei Trakt eingegeben ist.
    func verbinden() {
        guard let client, let konto else { return }
        vorgang?.cancel()
        anmeldung = .holtCode
        vorgang = Task { [weak self] in
            do {
                let code = try await client.geraetecode()
                self?.anmeldung = .code(code, bis: Date().addingTimeInterval(code.gueltig))
                var neu = try await client.freigabeAbwarten(code)
                neu.benutzer = await client.benutzername(neu)
                guard let self, !Task.isCancelled else { return }
                self.speichern(neu, konto: konto)
                if self.konto == konto {
                    self.token = neu
                    self.melder?.tokenSetzen(neu, kennung: konto)
                }
                self.anmeldung = .keine
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.anmeldung = .fehler(Self.text(error))
            }
        }
    }

    /// Seite geschlossen oder „Abbrechen".
    func abbrechen() {
        vorgang?.cancel()
        vorgang = nil
        anmeldung = .keine
    }

    /// **„Trennen", nicht „Abmelden"** — wie bei Seerr. Bei Trakt bleibt der
    /// Verlauf, wie er ist; nur dieser Zugang geht.
    func trennen() {
        guard let konto else { return }
        let alt = token
        token = nil
        speichern(nil, konto: konto)
        melder?.tokenSetzen(nil, kennung: konto)
        if let alt, let client { Task { await client.widerrufen(alt) } }
    }

    private static func text(_ fehler: any Error) -> String {
        switch fehler as? TraktFehler {
        case .codeAbgelaufen: String(localized: "Der Code ist abgelaufen. Hol dir einen neuen.")
        case .abgelehnt:      String(localized: "Trakt hat die Verbindung nicht freigegeben.")
        case .ratenlimit:     String(localized: "Trakt bremst gerade. Versuch es in ein paar Minuten noch mal.")
        default:              String(localized: "Trakt ist gerade nicht erreichbar.")
        }
    }

    // MARK: Wiedergabe — aufgerufen aus `AppModel`, neben den Jellyfin-Meldungen

    func start(item: Item, client: JellyfinClient?, sekunden: Double) {
        guard let melder, token != nil, let client else { return }
        melder.melden(.start(titelID: item.id,
                             ziel: { await TraktZiel.aufloesen(item, client: client) },
                             stelle: sekunden, dauer: item.runtimeSeconds ?? 0))
    }

    func laufzustand(laeuft: Bool, sekunden: Double) {
        melder?.melden(.laufzustand(laeuft: laeuft, stelle: sekunden))
    }

    func sprung(sekunden: Double) {
        melder?.melden(.sprung(stelle: sekunden))
    }

    func stopp(item: Item, sekunden: Double) {
        melder?.melden(.stopp(titelID: item.id, stelle: sekunden))
    }
}
