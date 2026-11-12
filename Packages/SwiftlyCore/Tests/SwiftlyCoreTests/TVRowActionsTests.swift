import Testing

@testable import SwiftlyCore

@Suite("TV detail row actions")
struct TVRowActionsTests {
    private func entry(_ kind: MenuKind) -> MenuEntry { MenuEntry(kind: kind, text: "\(kind)") }

    @Test func seriesMovesShuffleAndTogetherOutOfThePanel() {
        let actions = TVRowActions(menu: [entry(.nextEpisode), entry(.shuffle), entry(.together), entry(.refreshMetadata)])
        #expect(actions.shuffle?.kind == .shuffle)
        #expect(actions.together?.kind == .together)
        #expect(actions.panel.map(\.kind) == [.nextEpisode, .refreshMetadata])
    }

    @Test func missingEntriesGiveNoButtons() {
        let actions = TVRowActions(menu: [entry(.playFromStart), entry(.refreshMetadata)])
        #expect(actions.shuffle == nil)
        #expect(actions.together == nil)
        #expect(actions.panel.count == 2)
    }

    @Test func emptyMenu() {
        let actions = TVRowActions(menu: [])
        #expect(actions.shuffle == nil && actions.together == nil && actions.panel.isEmpty)
    }
}
