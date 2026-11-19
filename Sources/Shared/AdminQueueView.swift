import JellyfinKit
import SwiftUI
import SwiftlyCore

/// **"Verwaltung"**: the tabs "Anfragen" and "Probleme" (each only with its right), the filter row, and one row per
/// request with "Freigeben" / "Ablehnen" (and "Nochmal" on a failed one). A row opens the request's detail card.
///
/// Nothing is decided here: the core hands over the tabs with their counts, the pills, the rows and which verbs
/// each row offers; the page comes in as a whole once the first answer is there.
struct AdminQueueView: View {
    let model: AppModel
    /// Inside the Verwaltung page: only the request queue, no header, tabs or scrolling of its own (the hub has them).
    var embedded = false

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @State private var flow = SeerrAdminFlow()
    @State private var tab = 0
    @State private var declining: SwiftlyCore.SeerrRequestRow?
    @State private var declineOpen = false

    private var current: SwiftlyCore.AdminTab? {
        flow.tabs.indices.contains(tab) ? flow.tabs[tab].tab : flow.tabs.first?.tab
    }

    var body: some View {
        if embedded {
            content
                .opacity(flow.settled ? 1 : 0)
                .animation(Theme.reveal, value: flow.settled)
                .hubSheet(id: "decline") { DeclineSheet(opened: $declineOpen, title: declining?.title ?? "") { decline() } }
                .task { await flow.load(model) }
        } else {
            page
        }
    }

    private func decline() {
        guard let row = declining else { return }
        Task { await flow.decline(row.id) }
    }

    private var page: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            ScrollView {
                content
                    .opacity(flow.settled ? 1 : 0)
                    .animation(Theme.reveal, value: flow.settled)
            }
            .scrollIndicators(.hidden)
            .fadingUnderSubpageHeader(title: String(localized: "Verwaltung")) { back() }
            .refreshable { await flow.load(model) }

            DeclineSheet(opened: $declineOpen, title: declining?.title ?? "") {
                guard let row = declining else { return }
                Task { await flow.decline(row.id) }
            }
            .zIndex(20)
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        .task { await flow.load(model) }
    }

    @ViewBuilder private var content: some View {
        if flow.settled, !flow.connected || flow.tabs.isEmpty {
            EmptyState(symbol: "tray", headerLine: "Nichts zu verwalten",
                       text: "Hier erscheint, worüber du bei Seerr entscheidest.")
                .frame(minHeight: 420)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if flow.tabs.count > 1, !embedded {
                    PageTab(title: flow.tabs.map { LocalizedStringKey("\($0.title) \($0.count)") }, selected: $tab)
                        .padding(.bottom, 4)
                }
                switch embedded ? .requests : current {
                case .requests: queue
                case .issues: AdminIssuesContent(model: model, flow: flow)
                case nil: EmptyView()
                }
            }
            .padding(.bottom, 40)
            .frame(maxWidth: wide ? Theme.readWidth : .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var queue: some View {
        if let info = flow.queue {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(info.pills, id: \.pill) { pill in
                        SelectionChip(text: "\(pill.title) \(pill.count)", an: pill.selected) {
                            Theme.jerk(.lightweight)
                            withAnimation(Theme.reveal) { flow.selectPill(pill.pill) }
                        }
                    }
                }
                .padding(.horizontal, Theme.margin(wide: wide))
            }
            .padding(.vertical, 14)
            if info.rows.isEmpty {
                EmptyState(symbol: "checkmark.circle", headerLine: "Nichts zu entscheiden",
                           text: "Neue Anfragen erscheinen hier.")
                    .frame(minHeight: 320)
            }
            ForEach(info.rows) { row in
                AdminQueueRow(
                    row: row,
                    detail: RequestDetailView(model: model, flow: flow, id: row.id),
                    approve: { Theme.jerk(.medium); Task { await flow.approve(row.id) } },
                    decline: { declining = row; declineOpen = true },
                    retry: { Theme.jerk(.medium); Task { await flow.retry(row.id) } })
                    .transition(.opacity)
            }
            // A row that left the filter closes up with the page's change motion.
            .animation(Theme.reveal, value: info.rows.map(\.id))
        }
    }
}

/// One request of the queue: poster, title, who asked and what, its state, and the verbs the core allows.
/// The poster and words open the detail card; the verbs are siblings of that link, never inside it.
private struct AdminQueueRow: View {
    let row: SwiftlyCore.SeerrRequestRow
    let detail: RequestDetailView
    let approve: () -> Void
    let decline: () -> Void
    let retry: () -> Void

    @Environment(\.wide) private var wide

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink { detail } label: { summary }
                .buttonStyle(Theme.PressRow())
            if row.work == .working {
                Text(verbatim: row.workText ?? "")
                    .font(.app(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.leading, 64 + 12)
            } else if row.canApprove || row.canDecline || row.canRetry {
                HStack(spacing: 8) {
                    if row.canApprove {
                        ValuePill(symbol: "checkmark", text: String(localized: "Freigeben"), perform: approve)
                            .accessibilityIdentifier("approve-\(row.id)")
                    }
                    if row.canDecline {
                        ValuePill(symbol: "xmark", text: String(localized: "Ablehnen"), perform: decline)
                            .accessibilityIdentifier("decline-\(row.id)")
                    }
                    if row.canRetry {
                        ValuePill(symbol: "arrow.clockwise", text: String(localized: "Nochmal"), perform: retry)
                            .accessibilityIdentifier("retry-\(row.id)")
                    }
                }
                .padding(.leading, 64 + 12)
                if row.work == .failed, let text = row.workText {
                    Text(verbatim: text)
                        .font(Theme.small)
                        .foregroundStyle(Theme.error)
                        .padding(.leading, 64 + 12)
                }
            }
        }
        .padding(.horizontal, Theme.margin(wide: wide))
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 12) {
            Picture(url: row.poster.flatMap { URL(string: $0) }, corner: Theme.cornerTile)
                .frame(width: 64, height: 96)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: row.title)
                    .growing(15, .semibold)
                    .foregroundStyle(Theme.font)
                    .lineLimit(2)
                Text(verbatim: meta)
                    .growing(12)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(icon: row.badge.symbol, size: 11)
                        .font(.app(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(verbatim: row.badge.line)
                        .growing(13, .medium)
                        .lineLimit(2)
                }
                .foregroundStyle(row.badge.kind.tint)
                .padding(.top, 2)
                if let progress = row.badge.progress {
                    ProgressBar(share: Double(progress), round: true)
                        .padding(.top, 5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        let art = row.art == "tv" ? String(localized: "Serie") : String(localized: "Film")
        return [art, row.detail, row.requestedBy].compactMap { $0 }.joined(separator: " · ")
    }
}
