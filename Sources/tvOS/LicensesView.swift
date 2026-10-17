import SwiftUI

// Settings > Open-source licenses (Apple TV).
// Left the components, right what belongs to the focused one: details, source and full text.
// The TV has no pointer and no browser, so every paragraph on the right is focusable and
// scrolling happens by moving focus, as the remote does anyway. Addresses are shown as text
// to type. The data comes from `LicenseState`, the same source as on the other platforms;
// the license wording stays English.

struct TVLicensesView: View {
    let close: () -> Void

    private enum Choice: Hashable {
        case offering
        case component(String)
    }
    private enum Place: Hashable {
        case left(Choice)
        case right(Int)
    }

    private let inventory = LicenseState.shared
    @State private var choice: Choice = .offering
    @FocusState private var place: Place?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.reason.ignoresSafeArea()
            HStack(alignment: .top, spacing: 72) {
                left
                    .frame(width: 560, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .focusSection()
                right
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .focusSection()
            }
            .padding(.horizontal, Theme.edgePage)
            .padding(.vertical, Theme.edgeTop)
        }
        .ignoresSafeArea(edges: .horizontal)
        .defaultFocus($place, .left(.offering))
        .onChange(of: place) { _, new in
            if case let .left(w) = new { choice = w }
        }
        // Back from the text goes to the list first; only a second Back leaves the page, as in the profile.
        .onExitCommand {
            if case .right = place { place = .left(choice) } else { close() }
        }
    }

    // MARK: Left

    private var left: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Open-Source-Lizenzen")
                .font(Theme.titleLarge)
                .foregroundStyle(Theme.font)
                .padding(.leading, 26)
                .padding(.bottom, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let inventory {
                        GroupsTitle(text: "VLCKit und libVLC")
                        ForEach(inventory.components(group: "player")) { b in row(.component(b.id), b.name) }
                        row(.offering, String(localized: "Quelltext und schriftliches Angebot"))
                        group("Weitere Bausteine", inventory.components(group: "app"))
                        group("In VLCKit eingebaut", inventory.components(group: "in-vlckit"))
                    } else {
                        row(.offering, String(localized: "Quelltext und schriftliches Angebot"))
                    }
                }
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    @ViewBuilder
    private func group(_ title: LocalizedStringKey, _ list: [LicenseComponent]) -> some View {
        if !list.isEmpty {
            GroupsTitle(text: title).padding(.top, 36)
            ForEach(list) { b in row(.component(b.id), b.name) }
        }
    }

    private func row(_ target: Choice, _ name: String) -> some View {
        ActionRow(name: name) { place = .right(0) }
            .focused($place, equals: .left(target))
    }

    // MARK: Right

    private var right: some View {
        let blocks = self.blocks
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { spot, block in
                    Button {} label: {
                        Text(verbatim: block.text)
                            .font(block.title ? Theme.rail : Theme.body)
                            .lineSpacing(5)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(LicenseBlockStyle(title: block.title))
                    .focused($place, equals: .right(spot))
                }
            }
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .id(choice)
    }

    private struct Block {
        let text: String
        var title = false
    }

    private var blocks: [Block] {
        guard let inventory else {
            return [Block(text: String(localized: "Die Lizenzliste fehlt in dieser Fassung. Du findest sie auf GitHub in THIRD-PARTY-NOTICES.md."))]
        }
        switch choice {
        case .offering:
            var result: [Block] = [Block(text: inventory.offering.title, title: true)]
            for segment in inventory.offering.sections {
                result.append(Block(text: segment.title, title: true))
                result += segment.paragraphs.map { Block(text: $0) }
            }
            return result
        case let .component(id):
            guard let b = inventory.component(id: id) else { return [] }
            var result: [Block] = [
                Block(text: b.name, title: true),
                Block(text: "\(String(localized: "Fassung")): \(b.version)\n\(String(localized: "Lizenz")): \(b.spdx)\n\(String(localized: "Urheber")): \(b.author)\n\(String(localized: "Quelle")): \(b.source)"),
            ]
            if let note = b.note { result.append(Block(text: note)) }
            for file in b.texts {
                guard let text = LicenseState.text(file) else {
                    result.append(Block(text: String(localized: "Der Text fehlt in dieser Fassung.")))
                    continue
                }
                result.append(Block(text: String(localized: "Lizenztext"), title: true))
                result += LicenseState.paragraphs(from: text).map { Block(text: $0) }
            }
            return result
        }
    }
}

/// A paragraph of the full text: flat at rest, the calm fill of every row in the app when focused.
private struct LicenseBlockStyle: ButtonStyle {
    let title: Bool

    func makeBody(configuration: Configuration) -> some View {
        ContentBody(configuration: configuration, title: title)
    }

    private struct ContentBody: View {
        let configuration: ButtonStyleConfiguration
        let title: Bool
        @Environment(\.isFocused) private var focus

        var body: some View {
            configuration.label
                .foregroundStyle(title || focus ? Theme.font : Theme.fontQuiet)
                .padding(.horizontal, 26)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(focus ? Theme.focusArea : Color.clear,
                            in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .animation(Theme.focusAnimation, value: focus)
        }
    }
}
