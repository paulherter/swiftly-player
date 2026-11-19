import JellyfinKit
import SwiftUI
import SwiftlyCore

/// **"Meine Anfragen"**: what the account asked Seerr for, with a filter row, the state of each title in the core's
/// words, a progress bar where it is on its way, and "Zurückziehen" for an own request that still waits.
///
/// The page comes in as a whole once the first answer is there (nothing pops in on its own); the rows are plain
/// rows with no separators, like the download list. Nothing is decided here: the core hands over rows, pills,
/// the quota line and whether anything may be withdrawn.
struct RequestsView: View {
    let model: AppModel
    /// Inside the Verwaltung page ("Meine Anfragen" section): no header or scrolling of its own.
    var embedded = false

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @State private var flow = SeerrRequestsFlow()
    /// The core's admin screen behind a request's detail card (read, withdraw); the list reads again when it changes.
    @State private var detailFlow = SeerrAdminFlow()

    var body: some View {
        if embedded {
            content
                .opacity(flow.settled ? 1 : 0)
                .animation(Theme.reveal, value: flow.settled)
                .task { await flow.load(model) }
        } else {
            page
        }
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
            .fadingUnderSubpageHeader(title: String(localized: "Meine Anfragen")) { back() }
            .refreshable { await flow.load(model) }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        .task { await flow.load(model) }
    }

    @ViewBuilder private var content: some View {
        if let info = flow.info, info.load == .content || info.load == .loading {
            VStack(alignment: .leading, spacing: 0) {
                pills(info)
                if let quota = info.quotaSummary {
                    QuotaLine(text: quota)
                        .padding(.horizontal, Theme.margin(wide: wide))
                        .padding(.bottom, 6)
                }
                ForEach(info.rows) { row in
                    RequestRow(row: row,
                               detail: RequestDetailView(model: model, flow: detailFlow, id: row.id,
                                                         changed: { Task { await flow.load(model) } }),
                               withdraw: { Task { await withdraw(row.id) } })
                        .transition(.opacity)
                }
            }
            .padding(.bottom, 40)
            // The row that was withdrawn closes up with the page's change motion.
            .animation(Theme.reveal, value: info.rows.map(\.id))
            .frame(maxWidth: wide ? Theme.readWidth : .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if flow.settled {
            nothing(flow.info)
        }
    }

    private func pills(_ info: SwiftlyCore.SeerrRequestsInfo) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(info.pills, id: \.pill) { pill in
                    SelectionChip(text: "\(pill.title) \(pill.count)", an: pill.selected) {
                        Theme.jerk(.lightweight)
                        withAnimation(Theme.reveal) { flow.select(pill.pill) }
                    }
                }
            }
            .padding(.horizontal, Theme.margin(wide: wide))
        }
        .padding(.vertical, 14)
    }

    /// Empty list, no Seerr, or Seerr does not answer: one calm block, no list.
    @ViewBuilder private func nothing(_ info: SwiftlyCore.SeerrRequestsInfo?) -> some View {
        if let error = info?.error, info?.load == .offline || info?.load == .failed {
            EmptyState(symbol: "wifi.slash", headerLine: "Seerr antwortet gerade nicht", text: LocalizedStringKey(error),
                       quietButton: ("Erneut versuchen", { Task { await flow.load(model) } }))
                .frame(minHeight: 420)
        } else {
            EmptyState(symbol: "tray", headerLine: "Noch nichts angefragt",
                       text: "Was du bei Seerr anfragst, steht hier mit seinem Stand.")
                .frame(minHeight: 420)
        }
    }

    private func withdraw(_ id: Int64) async {
        Theme.jerk(.medium)
        await flow.withdraw(id)
    }
}

/// One request: poster, title, "Film" / "Serie · Staffel 2", the state in the core's words with its symbol, a
/// capsule bar while it is being fetched, and the withdraw pill on an own waiting request.
private struct RequestRow: View {
    let row: SwiftlyCore.SeerrRequestRow
    let detail: RequestDetailView
    let withdraw: () -> Void

    @Environment(\.wide) private var wide

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The poster and the words open the request's detail card; "Zurückziehen" is a sibling of the link.
            NavigationLink { detail } label: { summary }
                .buttonStyle(Theme.PressRow())
            if row.canWithdraw {
                ValuePill(symbol: "arrow.uturn.backward", text: String(localized: "Zurückziehen"), perform: withdraw)
                    .padding(.leading, 64 + 12)
            }
        }
        .padding(.horizontal, Theme.margin(wide: wide))
        .padding(.vertical, 10)
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
        return [art, row.detail].compactMap { $0 }.joined(separator: " · ")
    }
}
