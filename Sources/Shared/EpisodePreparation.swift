import Foundation
import JellyfinKit
import Network

/// **Prepare the next episode in the last minutes**: fetch the plan and request
/// the start of the file once, so the switch goes without a spinner. When and how
/// much is decided by ``Prebuffer`` in the package.
///
/// The player stays one: no second media, no second VLC. On the switch,
/// `toNextEpisode` takes the finished plan instead of fetching it, and the
/// server delivers the start from memory instead of from disk.
@MainActor
final class EpisodePreparation {
    private struct Finished {
        let id: String
        let plan: PlaybackPlan
        let moment: Date
    }

    private var done: Finished?
    /// The episode being or having been prepared, once per episode, even if it
    /// fails.
    private var begun: String?
    private var task: Task<Void, Never>?

    /// Wi-Fi or cable, without Low Data Mode. Kept current by the network monitor.
    private(set) var networkFavorable = false
    private let sentry = NWPathMonitor()

    init() {
        sentry.pathUpdateHandler = { [weak self] path in
            let favorable = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            Task { @MainActor in self?.networkFavorable = favorable }
        }
        sentry.start(queue: DispatchQueue(label: "de.paulherter.swiftly.vorpuffer"))
    }

    deinit { sentry.cancel() }

    /// Trigger once per episode; any further call for the same one does nothing.
    func prepare(_ episode: Item, planOut: @escaping () async -> PlaybackPlan?) {
        guard begun != episode.id else { return }
        begun = episode.id
        done = nil
        task?.cancel()
        task = Task { [weak self] in
            let beginning = Date()
            guard let plan = await planOut(), !Task.isCancelled else { return }
            self?.done = Finished(id: episode.id, plan: plan, moment: Date())
            AppLog.writeOut("[Vorpuffer] Plan bereit nach \(Self.ms(since: beginning)) ms"
                + " · \(plan.method.wireName)")
            guard Prebuffer.startLoad(address: plan.url, method: plan.method) else { return }
            await Self.startLoad(plan.url)
        }
    }

    /// The finished plan for this episode, if there is one and it is still fresh.
    /// Once taken, it is used up.
    func take(_ id: String) -> PlaybackPlan? {
        defer { done = nil }
        guard let done, done.id == id,
              Prebuffer.freshValue(prepared: done.moment, now: Date()) else { return nil }
        return done.plan
    }

    /// Forget everything, for example after a quality choice that changes the plan.
    func forget() {
        task?.cancel()
        task = nil
        done = nil
        begun = nil
    }

    /// Request the start of the file once (`Prebuffer.startRequest`, with the
    /// server's own headers). The bytes themselves are discarded; the point is that
    /// the server then has them in memory.
    private static func startLoad(_ address: URL) async {
        let beginning = Date()
        do {
            let bytes = try await Prebuffer.startRequest(address)
            AppLog.writeOut("[Vorpuffer] Anfang vorgeladen: \(bytes / 1024) KB"
                + " in \(ms(since: beginning)) ms")
        } catch {
            AppLog.writeOut("[Vorpuffer] Anfang nicht geladen: \(error.localizedDescription)")
        }
    }

    private static func ms(since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }
}
