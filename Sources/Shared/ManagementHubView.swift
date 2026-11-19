import JellyfinKit
import SwiftUI
import SwiftlyCore

/// **Profile > "Verwaltung" / "Meine Anfragen"**: the one page behind the one Profile row. The core decides the sections
/// (`profileEntry`): an administrator sees Anfragen (the Seerr queue), Meldungen and Server, everyone else their own
/// requests and reports; a section without right or data is not listed, and one section alone shows no tab bar.
///
/// Nothing is decided here: the page owns the header, the tab bar and the scrolling, and each section draws its own
/// screen content (the same Seerr and server screens as before, now without a page of their own).
struct ManagementHubView: View {
    let model: AppModel
    let route: ManagementHubRoute

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @State private var selected = 0

    private var section: ManagementHubRoute.Section? {
        route.sections.indices.contains(selected) ? route.sections[selected] : route.sections.first
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if route.sections.count > 1 {
                        PageTab(title: route.sections.map { LocalizedStringKey(label($0)) }, selected: $selected)
                            .padding(.bottom, 4)
                    }
                    content
                        .id(section?.kind)
                        .padding(.bottom, 40)
                }
                .frame(maxWidth: wide ? Theme.readWidth : .infinity, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .fadingUnderSubpageHeader(title: route.title) { back() }
        }
        // Sheets of the sections rest at screen level (the page root, outside the scroll content): attached to
        // content that is still empty, their closed card sat inside the visible frame while the list loaded.
        .overlayPreferenceValue(HubSheetKey.self) { sheets in
            ZStack { ForEach(sheets) { $0.view } }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        .accessibilityIdentifier("management-hub")
        #if DEBUG
        .onAppear {
            // Proof hook: `-SwiftlyOpenManagementTab issues|server|requests` starts on that section of the hub.
            let args = ProcessInfo.processInfo.arguments
            guard let at = args.firstIndex(of: "-SwiftlyOpenManagementTab"), at + 1 < args.count,
                  let index = route.sections.firstIndex(where: { $0.kind == args[at + 1] }) else { return }
            selected = index
        }
        #endif
    }

    private func label(_ section: ManagementHubRoute.Section) -> String {
        section.count > 0 ? "\(section.title) \(section.count)" : section.title
    }

    @ViewBuilder private var content: some View {
        if let section {
            switch section.kind {
            case "requests":
                if section.manage { AdminQueueView(model: model, embedded: true) }
                else { RequestsView(model: model, embedded: true) }
            case "issues": AdminIssuesView(model: model, embedded: true)
            case "server": ServerAdminView(model: model)
            default: EmptyView()
            }
        }
    }
}

/// One sheet a section hands up to the hub (``ManagementHubView``), which attaches it at screen level.
struct HubSheet: Identifiable, @unchecked Sendable {
    let id: String
    let view: AnyView
}

struct HubSheetKey: PreferenceKey {
    static let defaultValue: [HubSheet] = []
    static func reduce(value: inout [HubSheet], nextValue: () -> [HubSheet]) { value += nextValue() }
}

extension View {
    /// Hands `sheet` up to the hub instead of attaching it to this (scrolling) content.
    func hubSheet<S: View>(id: String, @ViewBuilder _ sheet: () -> S) -> some View {
        preference(key: HubSheetKey.self, value: [HubSheet(id: id, view: AnyView(sheet()))])
    }
}
