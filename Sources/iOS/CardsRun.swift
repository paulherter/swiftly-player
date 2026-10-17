#if DEBUG
import JellyfinKit
import SwiftUI
import UIKit

/// **Self-test of the episode card: does it lie inside the safe area?** Without a
/// server, without a finger, only via the log.
///
/// xcrun simctl launch <device> <bundle-id> -kartenlauf
///
/// Rotates to landscape, lays the card over the whole window and writes its frame
/// next to the safe-area insets (`[CardView] Rahmen …`), once without and once with
/// controls.
@MainActor
enum CardsRun {
    static var an: Bool { ProcessInfo.processInfo.arguments.contains("-kartenlauf") }

    private final class Snapshot: ObservableObject {
        @Published var controls = false
    }

    static func start() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            Orientierung.shared.setDown(.landscapeRight)
            try? await Task.sleep(for: .seconds(2))
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
            let state = Snapshot()
            let episode = Item(id: "karte", name: "Redbird", type: "Episode",
                             runTimeTicks: 2_600 * 10_000_000, indexNumber: 11, parentIndexNumber: 6)
            let root = UIHostingController(rootView: Stage(state: state, episode: episode))
            root.view.backgroundColor = .black
            root.view.frame = window.bounds
            root.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.addSubview(root.view)
            AppLog.writeOut("[Kartenlauf] Gerät \(UIDevice.current.model) · Fenster \(Int(window.bounds.width))×\(Int(window.bounds.height))")
            try? await Task.sleep(for: .seconds(2))
            state.controls = true
            try? await Task.sleep(for: .seconds(2))
            AppLog.writeOut("[Kartenlauf] Ende")
        }
    }

    private struct Stage: View {
        @ObservedObject var state: Snapshot
        let episode: Item
        private var mass: PlayerMetric { PlayerMetric(pad: Theme.atPad, inWindow: false) }

        var body: some View {
            EpisodeCardsView(episode: episode, imageAddress: nil, pad: Theme.atPad,
                                page: mass.page, present: !state.controls, zoom: 0, detailsPresent: true,
                                image: 1, fillContent: FillClock(), rest: 5,
                                onTap: {}, cancel: {})
        }
    }
}
#endif
