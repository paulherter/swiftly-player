import Foundation
import JellyfinKit

// MARK: - Watching together: what the kernel provides for Kotlin
//
// The logic lives in the package (`SyncPlaySession`). Only the bridge is here: the player as a
// `SyncPlayPlayer` that gets its state from the Kotlin tick and puts its steps into a slot Kotlin
// waits on; and the state as JSON. The public calls are in `Core.swift` ("Gemeinsam schauen").

/// **A slot that exactly one Kotlin call waits on.** If something is in it, the call returns at
/// once; otherwise it waits until something is put in, with no tick in between. The group's steps
/// must run at the time the session computed, not at the next tick.
///
/// A second waiter replaces the first with `""`: the first belonged to a player that is already
/// closed.
final class WaitCompartment: @unchecked Sendable {
    private let barrier = NSLock()
    private var lies: [String] = []
    private var waits: CheckedContinuation<String, Never>?

    func put(_ entryRecord: String) {
        barrier.lock()
        if let w = waits {
            waits = nil
            barrier.unlock()
            w.resume(returning: entryRecord)
            return
        }
        lies.append(entryRecord)
        if lies.count > 50 { lies.removeFirst() }
        barrier.unlock()
    }

    func fetch() async -> String {
        await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            barrier.lock()
            if !lies.isEmpty {
                let entryRecord = lies.removeFirst()
                barrier.unlock()
                c.resume(returning: entryRecord)
                return
            }
            let alt = waits
            waits = c
            barrier.unlock()
            alt?.resume(returning: "")
        }
    }

    /// Discard everything; whoever waits gets `""` and stops.
    func wipe() {
        barrier.lock()
        let w = waits
        waits = nil
        lies = []
        barrier.unlock()
        w?.resume(returning: "")
    }
}

/// **The state for Kotlin, with a version.** Every change increments the version; whoever asks with
/// an older version gets the current state at once, otherwise waits for the next. Several may wait
/// (phone and player).
final class StatusPanel: @unchecked Sendable {
    private let barrier = NSLock()
    private var state = 0
    private var text = "{}"
    private var waitingOnes: [CheckedContinuation<String, Never>] = []

    func setDown(_ new: String) {
        barrier.lock()
        state += 1
        text = new
        let all = waitingOnes
        waitingOnes = []
        let answer = Self.answer(state, new)
        barrier.unlock()
        for w in all { w.resume(returning: answer) }
    }

    func fetch(to: Int) async -> String {
        await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            barrier.lock()
            if state > to {
                let answer = Self.answer(state, text)
                barrier.unlock()
                c.resume(returning: answer)
                return
            }
            waitingOnes.append(c)
            barrier.unlock()
        }
    }

    private static func answer(_ state: Int, _ status: String) -> String {
        "{\"stand\":\(state),\"lage\":\(status)}"
    }
}

/// **The player as the session sees it**, counterpart of `SharedPlayer` on Apple.
///
/// Kotlin reports title, "ready", position and play state on the display tick (250 ms). In between
/// the position advances with the clock, but only if it really moved between two ticks: while VLC
/// buffers, it stands still. The steps (resume, pause, seek, load) go into a ``Wartefach`` that
/// Kotlin processes at once.
final class CorePlayer: SyncPlayPlayer, @unchecked Sendable {
    let mark: Int
    let steps = WaitCompartment()
    private let barrier = NSLock()
    private var _title: String
    private var _ready = false
    private var _point = 0.0
    private var _moved = false
    private var _um = Date()
    /// The title being switched to. Until Kotlin reports it, the player is not ready; otherwise "ready"
    /// would go out for the old one.
    private var _waits: String?

    init(title: String, mark: Int) {
        _title = title
        self.mark = mark
    }

    func tick(title: String, ready: Bool, spot: Double, running: Bool) {
        barrier.lock(); defer { barrier.unlock() }
        _moved = running && abs(spot - _point) > 0.01 && abs(spot - _point) < 3
        _title = title
        _ready = ready
        _point = spot
        _um = Date()
        if _waits == title { _waits = nil }
    }

    /// The group watches something else; Kotlin switches in the open player.
    func load(_ title: String, since: Double) {
        barrier.lock(); _waits = title; _ready = false; barrier.unlock()
        steps.put(Self.step(Step(art: "laden", value: since, title: title)))
    }

    func title() async -> String {
        barrier.lock(); defer { barrier.unlock() }
        return _title
    }

    func ready() async -> Bool {
        barrier.lock(); defer { barrier.unlock() }
        return _ready && _waits == nil
    }

    func spot() async -> Double {
        barrier.lock(); defer { barrier.unlock() }
        guard _moved else { return _point }
        return _point + min(max(Date().timeIntervalSince(_um), 0), 0.5)
    }

    func proceed() async { steps.put(Self.step(Step(art: "weiter"))) }
    func halt() async { steps.put(Self.step(Step(art: "anhalten"))) }

    func jump(_ target: Double) async {
        // Pull the position along right away: the session measures from here whether it is running.
        barrier.lock(); _point = target; _moved = false; _um = Date(); barrier.unlock()
        steps.put(Self.step(Step(art: "springen", value: target)))
    }

    struct Step: Encodable {
        enum CodingKeys: String, CodingKey {
            case art
            case value = "wert"
            case title = "titel"
        }
        let art: String
        var value: Double? = nil
        var title: String? = nil
    }

    static func step(_ s: Step) -> String {
        (try? String(data: JSONEncoder().encode(s), encoding: .utf8)) ?? "{}"
    }
}

// MARK: - What Kotlin reads

struct GroupsResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case participant = "teilnehmer"
        case names = "namen"
        case condition = "zustand"
    }
    let id, name: String
    /// All, as the server names them, for the column in the player.
    let participant: [String]
    /// Each name once, for "Anna and Ben are watching".
    let names: [String]
    let condition: String?

    init(_ g: SyncPlayGroup, condition: SyncPlayGroup.Phase? = nil) {
        id = g.id
        name = g.name
        participant = g.participant
        var watched = Set<String>()
        names = g.participant.filter { watched.insert($0).inserted }
        self.condition = Self.text(condition ?? g.condition)
    }

    static func text(_ z: SyncPlayGroup.Phase?) -> String? {
        switch z {
        case .running: return "laeuft"
        case .halted: return "angehalten"
        case .waits: return "wartet"
        case .empty, nil: return nil
        }
    }
}

struct EventResponse: Encodable {
    let id: String
    /// For the icon; the choice is up to the platform.
    let art: String
    /// Fully translated from the package.
    let text: String

    init(_ e: SyncPlayEvent) {
        id = e.id.uuidString
        text = e.text
        switch e.art {
        case .present: art = "dabei"
        case .gone: art = "gegangen"
        case .waitsOnAll: art = "wartet"
        case .halted: art = "angehalten"
        case .goesNext: art = "weiter"
        case .jumped: art = "gesprungen"
        case .noAccess, .notPlayable: art = "warnung"
        }
    }
}

/// **Everything the UI shows of the group**: ``SyncPlayStatus`` as JSON, plus who else is in it, and
/// the last error message.
struct SharedResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case mayCreate = "darfAnlegen"
        case offerings = "angebote"
        case group = "gruppe"
        case other = "andere"
        case event = "ereignis"
        case lastLeave = "zuletztVerlassen"
        case works = "arbeitet"
        case queueTitle = "schlangeTitel"
        case error = "fehler"
        case errorNumber = "fehlerNummer"
        case accepted = "angenommen"
    }
    let mayCreate, mayJoin: Bool
    let offerings: [GroupsResponse]
    let group: GroupsResponse?
    /// Without oneself, each name once, for "with Anna and Ben".
    let other: [String]
    let event: EventResponse?
    let lastLeave: String?
    let works: Bool
    let queueTitle: String?
    let error: String?
    let errorNumber: Int
    /// Increments as soon as the server accepted a create or join, then the sheet may close.
    let accepted: Int

    init(_ l: SyncPlayStatus, ich: String?, error: String?, errorNumber: Int, accepted: Int) {
        mayCreate = l.mayCreate
        mayJoin = l.mayJoin
        offerings = l.offerings.map { GroupsResponse($0) }
        group = l.group.map { GroupsResponse($0, condition: l.condition) }
        other = l.group?.other(asValue: ich) ?? []
        event = l.event.map(EventResponse.init)
        lastLeave = l.lastLeave?.name
        works = l.works
        queueTitle = l.queueTitle
        self.error = error
        self.errorNumber = errorNumber
        self.accepted = accepted
    }
}
