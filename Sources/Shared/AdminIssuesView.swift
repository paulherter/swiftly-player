import JellyfinKit
import SwiftUI
import SwiftlyCore

/// **"Meine Meldungen"**: the problems the account reported (everyone's for an issue manager), as its own page.
/// "Verwaltung" shows the same list in its "Probleme" tab.
struct AdminIssuesView: View {
    let model: AppModel
    /// Inside the Verwaltung page ("Meldungen" section): no header or scrolling of its own.
    var embedded = false

    @Environment(\.dismiss) private var back
    @State private var flow = SeerrAdminFlow()

    var body: some View {
        if embedded {
            AdminIssuesContent(model: model, flow: flow)
                .padding(.bottom, 40)
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
                AdminIssuesContent(model: model, flow: flow)
                    .padding(.bottom, 40)
                    .opacity(flow.settled ? 1 : 0)
                    .animation(Theme.reveal, value: flow.settled)
            }
            .scrollIndicators(.hidden)
            .fadingUnderSubpageHeader(title: String(localized: "Meine Meldungen")) { back() }
            .refreshable { await flow.load(model) }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        .task { await flow.load(model) }
    }
}

/// The problems list: filter pills (Offen / Erledigt / Alle with counts) and one row per problem. A row opens
/// its thread.
struct AdminIssuesContent: View {
    let model: AppModel
    let flow: SeerrAdminFlow

    @Environment(\.wide) private var wide
    #if DEBUG
    @State private var launchOpen: Int64?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let info = flow.issues {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(info.pills, id: \.pill) { pill in
                            SelectionChip(text: "\(pill.title) \(pill.count)", an: pill.selected) {
                                Theme.jerk(.lightweight)
                                withAnimation(Theme.reveal) { flow.selectIssuePill(pill.pill) }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.margin(wide: wide))
                }
                .padding(.vertical, 14)
                if info.rows.isEmpty {
                    EmptyState(symbol: "checkmark.circle", headerLine: "Keine Meldungen",
                               text: "Was beim Schauen nicht stimmt, steht hier.")
                        .frame(minHeight: 320)
                }
                ForEach(info.rows) { row in
                    NavigationLink {
                        IssueDetailView(model: model, flow: flow, id: row.id)
                    } label: {
                        IssueRow(row: row)
                    }
                    .buttonStyle(Theme.PressRow())
                    .accessibilityIdentifier("issue-\(row.id)")
                }
                .animation(Theme.reveal, value: info.rows.map(\.id))
            } else if flow.settled {
                EmptyState(symbol: "tray", headerLine: "Keine Meldungen",
                           text: "Was beim Schauen nicht stimmt, steht hier.")
                    .frame(minHeight: 420)
            }
        }
        .frame(maxWidth: wide ? Theme.readWidth : .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if DEBUG
        // Proof hook: `-SwiftlyOpenIssue` opens the first problem's thread as soon as the list is there.
        .navigationDestination(item: $launchOpen) { IssueDetailView(model: model, flow: flow, id: $0) }
        .task(id: flow.issues?.rows.first?.id) {
            guard ProcessInfo.processInfo.arguments.contains("-SwiftlyOpenIssue"), launchOpen == nil,
                  let first = flow.issues?.rows.first?.id else { return }
            try? await Task.sleep(for: .seconds(1))
            launchOpen = first
        }
        #endif
    }
}

/// One problem: poster, title, "Bild · Staffel 2 · Folge 3 · bei 23:14", its state and the first words.
private struct IssueRow: View {
    let row: SwiftlyCore.SeerrIssueRow

    @Environment(\.wide) private var wide

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Picture(url: row.poster.flatMap { URL(string: $0) }, corner: Theme.cornerTile)
                .frame(width: 48, height: 72)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: row.title).growing(15, .semibold).foregroundStyle(Theme.font).lineLimit(2)
                Text(verbatim: [row.kindWord, row.place, row.timeText].compactMap { $0 }.joined(separator: " · "))
                    .growing(13, .medium)
                    .foregroundStyle(Theme.fontQuiet)
                    .lineLimit(2)
                Text(verbatim: status)
                    .growing(12)
                    .foregroundStyle(row.isOpen ? Theme.warning : Theme.fontVeryQuiet)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.margin(wide: wide))
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        [row.statusWord, row.reporter].compactMap { $0 }.joined(separator: " · ")
    }
}

/// **One problem opened**: what was reported, the thread, a reply field, and "Erledigt" / "Wieder öffnen".
/// The core decides which of these the account may use.
struct IssueDetailView: View {
    let model: AppModel
    let flow: SeerrAdminFlow
    let id: Int64

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @State private var settled = false
    @State private var reply = ""
    @State private var sending = false
    @FocusState private var typing: Bool

    private var detail: SwiftlyCore.SeerrIssueDetail? { flow.issue?.row.id == id ? flow.issue : nil }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            ScrollView {
                content
                    .opacity(settled ? 1 : 0)
                    .animation(Theme.reveal, value: settled)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .fadingUnderSubpageHeader(title: detail?.row.title ?? String(localized: "Meldung")) { back() }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        .task {
            await flow.attach(model)
            await flow.openIssue(id)
            settled = true
        }
        .onDisappear { flow.closeIssue() }
    }

    @ViewBuilder private var content: some View {
        if let detail {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: detail.row.title).growing(20, .bold).lineLimit(3)
                    Text(verbatim: [detail.row.kindWord, detail.row.place, detail.row.timeText]
                        .compactMap { $0 }.joined(separator: " · "))
                        .growing(14, .medium)
                        .foregroundStyle(Theme.fontQuiet)
                    Text(verbatim: [detail.row.statusWord, detail.row.reporter].compactMap { $0 }.joined(separator: " · "))
                        .growing(12)
                        .foregroundStyle(detail.row.isOpen ? Theme.warning : Theme.fontVeryQuiet)
                }
                .padding(.horizontal, Theme.margin(wide: wide))
                .accessibilityElement(children: .combine)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(detail.messages) { message in
                        Bubble(message: message)
                    }
                }
                .padding(.horizontal, Theme.margin(wide: wide))

                if let error = detail.error {
                    Text(verbatim: error).font(Theme.small).foregroundStyle(Theme.error)
                        .padding(.horizontal, Theme.margin(wide: wide))
                }
                if detail.canReply { replyField }
                verbs(detail)
            }
            .padding(.bottom, 40)
            .frame(maxWidth: wide ? Theme.readWidth : .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if settled {
            EmptyState(symbol: "wifi.slash", headerLine: "Seerr antwortet gerade nicht",
                       text: "Diese Meldung lässt sich gerade nicht lesen.")
                .frame(minHeight: 420)
        }
    }

    private var replyField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Antwort schreiben …", text: $reply, axis: .vertical)
                .font(.app(size: 15))
                .lineLimit(1...4)
                .focused($typing)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
                .accessibilityIdentifier("issue-reply-field")
            Button {
                let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !sending else { return }
                sending = true
                Task {
                    await flow.reply(text)
                    reply = ""
                    sending = false
                }
            } label: {
                Image(icon: "arrow.up.circle.fill", size: 30)
                    .font(.app(size: 30))
                    .foregroundStyle(reply.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.fontVeryQuiet : Theme.accent)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(Theme.PressButton())
            .accessibilityLabel(Text("Senden"))
            .accessibilityIdentifier("issue-reply-send")
        }
        .padding(.horizontal, Theme.margin(wide: wide))
    }

    @ViewBuilder private func verbs(_ detail: SwiftlyCore.SeerrIssueDetail) -> some View {
        VStack(spacing: 10) {
            if detail.canResolve {
                Button {
                    Theme.jerk(.medium)
                    Task { await flow.resolve() }
                } label: { Text("Erledigt") }
                    .buttonStyle(PrimaryButtonStyle(stretches: true))
                    .accessibilityIdentifier("issue-resolve")
            }
            if detail.canReopen {
                Button {
                    Theme.jerk(.medium)
                    Task { await flow.reopen() }
                } label: { Text("Wieder öffnen") }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.horizontal, Theme.margin(wide: wide))
    }
}

/// One message of the thread; an administrator's reads in the accent so the thread shows who decides.
private struct Bubble: View {
    let message: SwiftlyCore.SeerrIssueMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: [message.author, message.whenText].compactMap { $0 }.joined(separator: " · "))
                .font(.app(size: 12, weight: .semibold))
                .foregroundStyle(message.byAdmin ? Theme.accent : Theme.fontQuiet)
            Text(verbatim: message.text)
                .font(.app(size: 15))
                .foregroundStyle(Theme.font)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.groupsArea, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
