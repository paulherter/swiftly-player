import SwiftUI
import SwiftlyCore

/// **Profile > "Verwaltung" / "Meine Anfragen" on the TV**: the one row the core decides (`ManagementEntryFlow`) and
/// the page behind it, a row of focusable tabs over the core's sections (one section alone: no tab row). The sections
/// and their words come from the core; this file only draws them for the remote.
struct TVManagementEntryRow: View {
    let model: AppModel
    let open: (ManagementHubRoute) -> Void

    @State private var flow = ManagementEntryFlow()

    var body: some View {
        // A stack, not a `Group`: the content is empty until the first answer, and a modifier on an empty view never appears, so its `.task` never ran.
        VStack(spacing: 0) {
            if let entry = flow.entry, !entry.sections.isEmpty {
                ActionRow(icon: entry.kind == .admin ? "speedometer" : "arrow.down.circle",
                          name: entry.title,
                          value: entry.kind == .admin && entry.count > 0 ? "\(entry.count)" : nil) {
                    open(ManagementHubRoute(entry))
                }
                .transition(.opacity)
            }
        }
        .animation(Theme.reveal, value: flow.entry)
        .task(id: "\(model.seerr.connected)-\(model.seerr.carries)") { await flow.load(model) }
    }
}

struct TVManagementHub: View {
    let model: AppModel
    let route: ManagementHubRoute
    let close: () -> Void

    @State private var selected = 0
    @FocusState private var focusedTab: Int?
    /// Height of the strip under the tabs where a scrolled list fades out (the gap the list starts below).
    private static let listFade: CGFloat = 36

    private var section: ManagementHubRoute.Section? {
        route.sections.indices.contains(selected) ? route.sections[selected] : route.sections.first
    }

    var body: some View {
        ZStack {
            Theme.reason.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: route.title)
                    .font(Theme.titleLarge)
                    .foregroundStyle(Theme.font)
                if route.sections.count > 1 {
                    HStack(spacing: 20) {
                        ForEach(Array(route.sections.enumerated()), id: \.offset) { index, item in
                            Button { withAnimation(Theme.reveal) { selected = index } } label: {
                                Text(verbatim: item.count > 0 ? "\(item.title) \(item.count)" : item.title)
                                    .font(Theme.body)
                                    .padding(.horizontal, 32).padding(.vertical, 14)
                            }
                            .buttonStyle(HubTabStyle(selected: index == selected))
                            .focused($focusedTab, equals: index)
                        }
                    }
                    .focusSection()
                    .padding(.top, 28)
                }
                Group {
                    if let section {
                        switch section.kind {
                        case "requests":
                            if section.manage { TVAdminQueue(model: model) } else { TVMyRequests(model: model) }
                        case "issues": TVAdminIssues(model: model)
                        case "server": TVServerAdmin(model: model)
                        default: EmptyState(symbol: "tray", title: LocalizedStringKey(section.title))
                        }
                    }
                }
                .id(section?.kind)
                // The list fades out in a strip under the tabs, so a scrolled row never runs over the title or the tabs.
                .fadesUnderHeader(Self.listFade)
            }
            .padding(.horizontal, Theme.edgePage)
            .padding(.top, Theme.edgeTop)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onExitCommand { close() }
        .defaultFocus($focusedTab, route.sections.count > 1 ? 0 : nil)
        #if DEBUG
        .onAppear {
            // Proof hook: `-SwiftlyOpenManagementTab issues|server|requests` starts on that section.
            let args = ProcessInfo.processInfo.arguments
            guard let at = args.firstIndex(of: "-SwiftlyOpenManagementTab"), at + 1 < args.count,
                  let index = route.sections.firstIndex(where: { $0.kind == args[at + 1] }) else { return }
            selected = index
        }
        #endif
        .accessibilityIdentifier("management-hub")
    }
}

struct HubTabStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected && !focused ? Theme.reason : Theme.font)
            .background(Capsule().fill(selected ? Theme.font.opacity(focused ? 0.9 : 1) : Theme.area))
            .overlay(Capsule().strokeBorder(Theme.font.opacity(focused ? 0.9 : 0), lineWidth: 4))
            .scaleEffect(focused ? 1.06 : 1)
            .animation(Theme.focusAnimation, value: focused)
    }
}

/// A focusable request row: the remote can move through the list and the page scrolls with the focus.
struct HubRowStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .fill(Theme.font.opacity(focused ? 0.14 : 0)))
            .scaleEffect(focused ? 1.015 : 1)
            .animation(Theme.focusAnimation, value: focused)
    }
}

private struct TVRequestRowView: View {
    let row: SwiftlyCore.SeerrRequestRow
    var withAsker = false

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            Picture(url: row.poster.flatMap { URL(string: $0) }, width: 80, height: 120, symbolText: "film")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: row.title).font(Theme.rail).foregroundStyle(Theme.font).lineLimit(1)
                Text(verbatim: meta).font(Theme.body).foregroundStyle(Theme.fontVeryQuiet).lineLimit(1)
                Text(verbatim: row.badge.line).font(Theme.body).foregroundStyle(row.badge.kind.tint).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var meta: String {
        let art = row.art == "tv" ? String(localized: "Serie") : String(localized: "Film")
        return [art, row.detail, withAsker ? row.requestedBy : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

struct TVPills: View {
    let pills: [SwiftlyCore.SeerrPillInfo]
    let select: (SwiftlyCore.RequestPill) -> Void

    var body: some View {
        HStack(spacing: 16) {
            ForEach(pills, id: \.pill) { pill in
                Button { select(pill.pill) } label: {
                    Text(verbatim: "\(pill.title) \(pill.count)").font(Theme.body)
                        .padding(.horizontal, 26).padding(.vertical, 10)
                }
                .buttonStyle(HubTabStyle(selected: pill.selected))
            }
        }
        .focusSection()
    }
}

/// The panel over a page: a heading and the subject's title (and the core's sentence), then the actions as an action
/// panel. The panel closes with Menu; the dimmed page behind it takes no focus.
struct TVAskLayer: View {
    var heading: LocalizedStringKey?
    let subject: String
    var sentence: LocalizedStringKey?
    let actions: [TitleAction]
    /// The row focus starts on (the safe one of a question).
    var start = 0
    let close: () -> Void

    var body: some View {
        ZStack {
            Theme.reason.opacity(0.94).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 10) {
                if let heading {
                    Text(heading).font(Theme.rail).foregroundStyle(Theme.font)
                }
                Text(verbatim: subject).font(Theme.body).foregroundStyle(Theme.fontQuiet).lineLimit(2)
                if let sentence {
                    Text(sentence).font(Theme.small).foregroundStyle(Theme.fontVeryQuiet)
                }
                ActionPanel(actions: actions, opened: Binding(get: { true }, set: { if !$0 { close() } }), start: start)
                    .padding(.top, 14)
            }
            .frame(width: ActionPanel.width, alignment: .leading)
        }
        .transition(.opacity)
    }
}

/// The request whose card is open (full screen over the list).
struct TVRequestCard: Identifiable {
    let id: Int64

    /// Proof hook: `-SwiftlyOpenRequest <id>` opens that request's card once the list stands.
    static func openForProof() async -> TVRequestCard? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let at = args.firstIndex(of: "-SwiftlyOpenRequest"), at + 1 < args.count, let id = Int64(args[at + 1]) else { return nil }
        try? await Task.sleep(for: .seconds(3))
        return TVRequestCard(id: id)
        #else
        return nil
        #endif
    }
}

/// Section "Anfragen" for an account that only reads its own: what it asked Seerr for (core rows and pills).
/// A row opens the request card, where "Zurückziehen" lives.
struct TVMyRequests: View {
    let model: AppModel
    @State private var flow = SeerrRequestsFlow()
    @State private var detailFlow = SeerrAdminFlow()
    @State private var card: TVRequestCard?

    var body: some View {
        // A stack, not a `Group`: the content is empty until the first answer, and a modifier on an empty view never appears, so its `.task` never ran.
        VStack(alignment: .leading, spacing: 0) {
            if let info = flow.info, info.load == .content || info.load == .loading {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        TVPills(pills: info.pills) { flow.select($0) }.padding(.bottom, 12)
                        ForEach(info.rows) { row in
                            Button {
                                card = TVRequestCard(id: row.id)
                            } label: { TVRequestRowView(row: row) }
                                .buttonStyle(HubRowStyle())
                        }
                    }
                    .padding(.bottom, 80)
                }
                .scrollClipDisabled()
            } else if flow.settled {
                EmptyState(symbol: "tray", title: "Noch nichts angefragt",
                           hint: "Was du bei Seerr anfragst, steht hier mit seinem Stand.")
            }
        }
        .opacity(flow.settled ? 1 : 0)
        .animation(Theme.reveal, value: flow.settled)
        .fullScreenCover(item: $card) { open in
            RequestDetailView(model: model, flow: detailFlow, id: open.id, changed: { Task { await flow.load(model) } })
        }
        .task { await flow.load(model) }
        .task { if let open = await TVRequestCard.openForProof() { card = open } }
    }
}

/// Section "Anfragen" for a manager: the queue of requests as the core lists it. A row opens the request card, which
/// offers the verbs the core allows (Freigeben, Nochmal, Ablehnen); "Ablehnen" asks once and sends no reason (Seerr takes none).
struct TVAdminQueue: View {
    let model: AppModel
    @State private var flow = SeerrAdminFlow()
    @State private var card: TVRequestCard?

    var body: some View {
        // A stack, not a `Group`: the content is empty until the first answer, and a modifier on an empty view never appears, so its `.task` never ran.
        VStack(alignment: .leading, spacing: 0) {
            if flow.settled, !flow.connected || flow.tabs.isEmpty {
                EmptyState(symbol: "tray", title: "Nichts zu verwalten",
                           hint: "Hier erscheint, worüber du bei Seerr entscheidest.")
            } else if let info = flow.queue {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        TVPills(pills: info.pills) { flow.selectPill($0) }.padding(.bottom, 12)
                        ForEach(info.rows) { row in
                            Button {
                                card = TVRequestCard(id: row.id)
                            } label: { TVRequestRowView(row: row, withAsker: true) }
                                .buttonStyle(HubRowStyle())
                        }
                    }
                    .padding(.bottom, 80)
                }
                .scrollClipDisabled()
            }
        }
        .opacity(flow.settled ? 1 : 0)
        .animation(Theme.reveal, value: flow.settled)
        .fullScreenCover(item: $card) { open in
            RequestDetailView(model: model, flow: flow, id: open.id)
        }
        .task { await flow.load(model) }
        .task { if let open = await TVRequestCard.openForProof() { card = open } }
    }
}

extension ManagementHubRoute: Identifiable {
    var id: String { title + ":" + sections.map(\.kind).joined(separator: ",") }
}
