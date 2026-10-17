import CGtk
import Foundation
import JellyfinKit

/// **Prepare the next episode in the last minutes:** fetch the plan and request
/// the start of the file once, so the switch happens without a spinner. `Prebuffer`
/// in the package decides when and how much; the flow mirrors
/// `Sources/iOS/EpisodePreparation.swift`.
///
/// The player stays one: no second media, no second libVLC. On the switch,
/// ``App/changeInto(_:ab:)`` takes the finished plan instead of fetching it, and
/// the server serves the start from memory instead of disk.
///
/// **The network question goes to GLib**, not `NWPathMonitor` (not available
/// here): `g_network_monitor_get_network_metered`, the same question the
/// downloads already ask (``Downloadverwaltung/wLAN``). Metered means mobile
/// data or a Wi-Fi marked as metered in NetworkManager; this corresponds to
/// `isExpensive || isConstrained` on Apple.
///
/// Lives on GTK's thread; only the plan and the file start run elsewhere.
final class EpisodePreparation: @unchecked Sendable {
    private struct Finished {
        let id: String
        let plan: PlaybackPlan
        let moment: Date
    }

    private var done: Finished?
    /// The episode being prepared or already prepared; once per episode, even if it
    /// fails.
    private var begun: String?
    private var task: Task<Void, Never>?
    /// Counts every ``vergessen()``: a plan arriving afterwards belongs to a state
    /// that no longer exists.
    private var round = 0

    /// Connected and not metered.
    var networkFavorable: Bool {
        guard let guards = g_network_monitor_get_default() else { return true }
        return g_network_monitor_get_network_available(guards) != 0
            && g_network_monitor_get_network_metered(guards) == 0
    }

    /// Trigger once per episode; further calls for the same one do nothing.
    func prepare(_ episode: Item, planOut: @escaping @Sendable () async -> PlaybackPlan?) {
        guard begun != episode.id else { return }
        begun = episode.id
        done = nil
        task?.cancel()
        let my = round
        task = Task.detached { [self] in
            let beginning = Date()
            guard let plan = await planOut(), !Task.isCancelled else { return }
            onMainThread {
                guard self.round == my, self.begun == episode.id else { return }
                self.done = Finished(id: episode.id, plan: plan, moment: Date())
            }
            AppLog.writeOut("[Vorpuffer] Plan bereit nach \(Self.ms(since: beginning)) ms · \(plan.method.wireName)")
            fflush(nil)
            guard Prebuffer.startLoad(address: plan.url, method: plan.method) else { return }
            await Self.startLoad(plan.url)
        }
    }

    /// The finished plan for this episode, if there is one and it is still fresh.
    /// Once taken, it is consumed.
    func take(_ id: String) -> PlaybackPlan? {
        defer { done = nil }
        guard let done, done.id == id,
              Prebuffer.freshValue(prepared: done.moment, now: Date()) else { return nil }
        return done.plan
    }

    /// Forget everything: after a quality choice that changes the plan, and when
    /// closing the player.
    func forget() {
        task?.cancel()
        task = nil
        done = nil
        begun = nil
        round += 1
    }

    /// Request the start of the file once (``Vorpuffer/startRequest(_:)`` in the
    /// package, with the server's own headers). The bytes are discarded; the point
    /// is that the server then has them in memory.
    private static func startLoad(_ address: URL) async {
        let beginning = Date()
        do {
            let count = try await Prebuffer.startRequest(address)
            AppLog.writeOut("[Vorpuffer] Anfang vorgeladen: \(count / 1024) KB in \(ms(since: beginning)) ms")
        } catch {
            AppLog.writeOut("[Vorpuffer] Anfang nicht geladen: \(error.localizedDescription)")
        }
        fflush(nil)
    }

    private static func ms(since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }
}
