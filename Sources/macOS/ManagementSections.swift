import JellyfinKit
import SwiftUI
import SwiftlyCore

// The sections "Meldungen" and "Server" of the management page (`MacManagementPage`). Same flows and the same core words
// as on iPhone (`SeerrAdminFlow`, `ServerAdminModel`, `ServerLogsModel`); only the drawing is the Mac's, with the Mac's
// rows, pills and window-level dialogs instead of sheets.

// MARK: - Meldungen

/// Section "Meldungen": the problems the account reported (everyone's for an issue manager), with the filter pills.
struct MacIssuesContent: View {
    let model: AppModel

    @State private var flow = SeerrAdminFlow()
    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section

    var body: some View {
        // In a stack: `content` is empty until the first answer, and a modifier on an empty view never appears, so its `.task` never ran.
        VStack(alignment: .leading, spacing: 0) { content }
            .opacity(flow.settled ? 1 : 0)
            .animation(Theme.reveal, value: flow.settled)
            .task { await flow.load(model) }
    }

    @ViewBuilder private var content: some View {
        if let info = flow.issues {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    ForEach(info.pills, id: \.pill) { pill in
                        Button { withAnimation(Theme.reveal) { flow.selectIssuePill(pill.pill) } } label: {
                            Text(verbatim: "\(pill.title) \(pill.count)")
                                .font(Theme.tile)
                                .foregroundStyle(pill.selected ? Theme.reason : Theme.font)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(pill.selected ? Theme.font : Theme.area, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(Theme.PressButton())
                        .accessibilityAddTraits(pill.selected ? .isSelected : [])
                    }
                    Spacer(minLength: 0)
                }
                if info.rows.isEmpty {
                    EmptyState(symbol: "checkmark.circle", headerLine: "Keine Meldungen",
                               text: "Was beim Schauen nicht stimmt, steht hier.")
                        .frame(minHeight: 320)
                }
                ForEach(info.rows) { row in
                    Button { navigator.openIt(.issue(row.id), in: section) } label: { MacIssueRow(row: row) }
                        .buttonStyle(Theme.PressRow())
                        .accessibilityIdentifier("issue-\(row.id)")
                        .transition(.opacity)
                }
                .padding(.top, 8)
            }
            .animation(Theme.reveal, value: info.rows.map(\.id))
        } else if flow.settled {
            EmptyState(symbol: "tray", headerLine: "Keine Meldungen",
                       text: "Was beim Schauen nicht stimmt, steht hier.")
                .frame(minHeight: 360)
        }
    }
}

/// One problem: poster, title, "Bild · Staffel 2 · Folge 3 · bei 23:14", its state.
private struct MacIssueRow: View {
    let row: SwiftlyCore.SeerrIssueRow

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Picture(url: row.poster.flatMap { URL(string: $0) }, corner: Theme.cornerTile)
                .frame(width: 48, height: 72)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: row.title).growing(15, .semibold).foregroundStyle(Theme.font).lineLimit(2)
                Text(verbatim: [row.kindWord, row.place, row.timeText].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.small).foregroundStyle(Theme.fontQuiet).lineLimit(2)
                Text(verbatim: [row.statusWord, row.reporter].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.small)
                    .foregroundStyle(row.isOpen ? Theme.warning : Theme.fontVeryQuiet)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One problem opened: what was reported, the thread, a reply field, and "Erledigt" / "Wieder öffnen" as far as the
/// core allows them to this account.
struct MacIssuePage: View {
    let model: AppModel
    let id: Int64
    let back: () -> Void

    @State private var flow = SeerrAdminFlow()
    @State private var settled = false
    @State private var reply = ""
    @State private var sending = false

    private var detail: SwiftlyCore.SeerrIssueDetail? { flow.issue?.row.id == id ? flow.issue : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SubpageHeader(name: detail?.row.title ?? String(localized: "Meldung"), back: back)
                content
                    .opacity(settled ? 1 : 0)
                    .animation(Theme.reveal, value: settled)
                    .padding(.top, 18)
            }
            .frame(maxWidth: Theme.readWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, Theme.contentTop)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .pagesScroll()
        .accessibilityIdentifier("issue-thread")
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
                    Text(verbatim: [detail.row.kindWord, detail.row.place, detail.row.timeText]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.body).foregroundStyle(Theme.fontQuiet)
                    Text(verbatim: [detail.row.statusWord, detail.row.reporter].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.small)
                        .foregroundStyle(detail.row.isOpen ? Theme.warning : Theme.fontVeryQuiet)
                }
                .accessibilityElement(children: .combine)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(detail.messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: [message.author, message.whenText].compactMap { $0 }.joined(separator: " · "))
                                .font(Theme.small.weight(.semibold))
                                .foregroundStyle(message.byAdmin ? Theme.accent : Theme.fontQuiet)
                            Text(verbatim: message.text)
                                .font(Theme.body).foregroundStyle(Theme.font)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Theme.groupsArea, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityElement(children: .combine)
                    }
                }
                if let error = detail.error {
                    Text(verbatim: error).font(Theme.small).foregroundStyle(Theme.error)
                }
                if detail.canReply { replyField }
                HStack(spacing: 8) {
                    if detail.canResolve { verb("checkmark", "Erledigt", id: "issue-resolve") { await flow.resolve() } }
                    if detail.canReopen { verb("arrow.uturn.backward", "Wieder öffnen", id: "issue-reopen") { await flow.reopen() } }
                    Spacer(minLength: 0)
                }
            }
        } else if settled {
            EmptyState(symbol: "wifi.slash", headerLine: "Seerr antwortet gerade nicht",
                       text: "Diese Meldung lässt sich gerade nicht lesen.")
                .frame(minHeight: 360)
        }
    }

    private var replyField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Antwort schreiben …", text: $reply, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .lineLimit(1...4)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
                .onSubmit(send)
                .accessibilityIdentifier("issue-reply-field")
            Button(action: send) {
                Image(icon: "arrow.up.circle.fill", size: 28)
                    .font(.app(size: 28))
                    .foregroundStyle(reply.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.fontVeryQuiet : Theme.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Theme.PressButton())
            .accessibilityLabel(Text("Senden"))
            .accessibilityIdentifier("issue-reply-send")
        }
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        Task {
            await flow.reply(text)
            reply = ""
            sending = false
        }
    }

    private func verb(_ symbol: String, _ text: LocalizedStringKey, id: String,
                      _ perform: @escaping () async -> Void) -> some View {
        Button { Task { await perform() } } label: {
            HStack(spacing: 5) {
                Image(icon: symbol).font(.app(size: 11, weight: .semibold))
                Text(text).font(Theme.tile)
            }
            .foregroundStyle(Theme.font)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.area, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(Theme.PressButton())
        .accessibilityIdentifier(id)
    }
}

// MARK: - Server

/// Section "Server": what the server is, what runs on it and who is watching, with scan, restart and the log files.
/// Nothing is decided here: the core's `ServerAdminModel` hands over every word and number, the confirm questions and
/// the one-second refresh (it runs only while this section is on screen).
struct MacServerContent: View {
    let model: AppModel

    @State private var admin: SwiftlyCore.ServerAdminModel?
    @State private var shownAsk: SwiftlyCore.ServerAdminAsk = .nothing
    @State private var asking = false
    @State private var streamMessage = ""
    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section

    init(model: AppModel) {
        self.model = model
        _admin = State(initialValue: try? AppCore.shared.serverAdmin(session: model.session))
    }

    private var state: SwiftlyCore.ServerAdminState { admin?.part.state ?? .loading }
    private var ask: SwiftlyCore.ServerAdminAsk {
        if case .ready(let page) = state { return page.ask }
        return .nothing
    }
    private var isReady: Bool {
        if case .loading = state { return false }
        return true
    }

    var body: some View {
        // In a stack: `content` is empty until the first answer, and a modifier on an empty view never appears, so its `.task` never ran.
        VStack(alignment: .leading, spacing: 0) { content }
            .opacity(isReady ? 1 : 0)
            .animation(Theme.reveal, value: isReady)
            .onChange(of: ask) { _, next in
                if next != .nothing {
                    shownAsk = next
                    if case .stopStream(_, _, _, _, let text, _) = next { streamMessage = text }
                    asking = true
                } else {
                    asking = false
                }
            }
            .onChange(of: asking) { _, open in
                // Dismissed with Escape or "Abbrechen": tell the core, so it asks again next time and sends nothing.
                if !open, ask != .nothing { admin?.send(.cancel) }
            }
            .alert(askTitle, isPresented: $asking) {
                if case .stopStream = shownAsk { TextField("", text: $streamMessage) }
                Button(askAction, role: .destructive) {
                    if case .stopStream = shownAsk { admin?.send(.confirm(message: streamMessage)) }
                    else { admin?.send(.confirm(message: nil)) }
                }
                .accessibilityIdentifier("server-ask-confirm")
                Button("Abbrechen", role: .cancel) {}
            } message: {
                if let note = askNote { Text(verbatim: note) }
            }
            .task { await admin?.run() }
    }

    private var askTitle: String {
        switch shownAsk {
        case .nothing: ""
        case .restart(let title, _, _): title
        case .stopTask(_, let title, _): title
        case .stopStream(_, let title, _, _, _, _): title
        }
    }
    private var askNote: String? {
        switch shownAsk {
        case .restart(_, let note, _): note
        case .stopStream(_, _, let line, _, _, _): line
        default: nil
        }
    }
    private var askAction: String {
        switch shownAsk {
        case .nothing: ""
        case .restart(_, _, let action): action
        case .stopTask(_, _, let action): action
        case .stopStream(_, _, _, _, _, let action): action
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading:
            Color.clear.frame(height: 600)
        case .ready(let page):
            pageBody(page)
        case .failed(let hint):
            notice(hint, retry: true)
        case .notAllowed(let hint):
            notice(hint, retry: false)
        }
    }

    private func notice(_ hint: String, retry: Bool) -> some View {
        VStack(spacing: 18) {
            Text(verbatim: hint).font(Theme.body).foregroundStyle(Theme.fontQuiet).multilineTextAlignment(.center)
            if retry {
                Button { admin?.send(.retry) } label: {
                    Text("Nochmal").font(Theme.tile).foregroundStyle(Theme.font)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.area, in: Capsule())
                }
                .buttonStyle(Theme.PressButton())
            }
        }
        .padding(.top, 120)
        .frame(maxWidth: .infinity)
    }

    private func group<Body: View>(_ title: String, @ViewBuilder _ body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: title).font(Theme.section).tracking(-0.2).foregroundStyle(Theme.font)
            CardView { body() }
        }
        .padding(.top, 26)
    }

    private func pageBody(_ page: SwiftlyCore.ServerAdminPage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            group(page.serverTitle) { serverCard(page) }
            if !page.tasks.isEmpty {
                group(page.tasksTitle) {
                    ForEach(Array(page.tasks.enumerated()), id: \.element.id) { i, task in
                        MacServerTask(task: task) { admin?.send(.askStopTask(id: task.id)) }
                        if i < page.tasks.count - 1 { GroupLine() }
                    }
                }
            }
            streams(page)
            if page.load != nil || !page.disks.isEmpty {
                group(page.loadTitle) { loadCard(page) }
            }
            group(page.actionsTitle) {
                ForEach(Array(page.actions.enumerated()), id: \.offset) { i, action in
                    if i > 0 { GroupLine() }
                    actionRow(action)
                }
            }
            if let text = page.notice {
                Text(verbatim: text).font(Theme.small).foregroundStyle(Theme.fontVeryQuiet).padding(.top, 12)
            }
        }
    }

    private func serverCard(_ page: SwiftlyCore.ServerAdminPage) -> some View {
        VStack(spacing: 0) {
            (Text(verbatim: page.name).foregroundStyle(Theme.font)
                + Text(verbatim: page.version.isEmpty ? "" : "  \(page.version)").foregroundStyle(Theme.fontVeryQuiet))
                .font(Theme.listTitle)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 14)
            if !page.counts.isEmpty { GroupLine(); MacServerNumbers(entries: page.counts) }
            if !page.resolutions.isEmpty { GroupLine(); MacServerNumbers(entries: page.resolutions) }
        }
    }

    @ViewBuilder private func streams(_ page: SwiftlyCore.ServerAdminPage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: page.streamsTitle).font(Theme.section).tracking(-0.2).foregroundStyle(Theme.font)
            if page.streams.isEmpty {
                Text(verbatim: page.streamsEmpty).font(Theme.body).foregroundStyle(Theme.fontVeryQuiet)
            }
            // A click on a card asks about stopping it, with a message to the viewer (the core words the question).
            ForEach(page.streams, id: \.id) { stream in
                Button { admin?.send(.askStopStream(sessionId: stream.sessionId)) } label: {
                    MacServerStream(model: model, stream: stream)
                }
                .buttonStyle(Theme.PressButton())
            }
        }
        .padding(.top, 26)
        .animation(Theme.reveal, value: page.streams.map(\.id))
    }

    private func loadCard(_ page: SwiftlyCore.ServerAdminPage) -> some View {
        VStack(spacing: 0) {
            if let load = page.load {
                if load.cpu != nil || load.memory != nil {
                    HStack(spacing: 28) {
                        if let cpu = load.cpu { MacServerRing(meter: cpu) }
                        if let memory = load.memory { MacServerRing(meter: memory) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                }
                if let io = load.diskIo {
                    if load.cpu != nil || load.memory != nil { GroupLine() }
                    MacServerMeter(title: io.label, value: io.text, share: nil)
                }
                if !page.disks.isEmpty { GroupLine() }
            }
            ForEach(Array(page.disks.enumerated()), id: \.element.id) { i, disk in
                MacServerMeter(title: disk.title, value: disk.freeText, share: disk.freeShare, warn: disk.nearlyFull)
                if i < page.disks.count - 1 { GroupLine() }
            }
        }
    }

    @ViewBuilder private func actionRow(_ action: SwiftlyCore.ServerAction) -> some View {
        let symbol = switch action.kind {
        case .scanLibraries: "arrow.triangle.2.circlepath"
        case .restart: "arrow.clockwise"
        case .logs: "doc.text"
        }
        Button {
            switch action.kind {
            case .logs: navigator.openIt(.serverLogs, in: section)
            case .scanLibraries: admin?.send(.scan)
            case .restart: admin?.send(.askRestart)
            }
        } label: {
            ValuesRow(symbol: symbol, title: Text(verbatim: action.title),
                      under: action.under.map { Text(verbatim: $0) }, accent: action.accent,
                      arrow: action.kind == .logs, hoverable: true)
        }
        .buttonStyle(Theme.PressRow())
        .accessibilityIdentifier(action.kind == .logs ? "server-logs" : action.kind == .restart ? "server-restart" : "server-scan")
    }
}

private struct MacServerNumbers: View {
    let entries: [SwiftlyCore.ServerNumber]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(entries, id: \.label) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.text).font(Theme.section).monospacedDigit().foregroundStyle(Theme.font)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(verbatim: entry.label).font(Theme.small).foregroundStyle(Theme.fontVeryQuiet).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}

private struct MacServerBar: View {
    let share: Double
    let tint: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.margin)
                Capsule().fill(tint).frame(width: g.size.width * min(max(share, 0), 1))
            }
        }
        .frame(height: 4)
        .animation(.linear(duration: 0.9), value: share)
    }
}

private struct MacServerMeter: View {
    let title: String
    let value: String
    let share: Double?
    var warn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: title).font(Theme.body).foregroundStyle(Theme.font).lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: value).font(Theme.tile).monospacedDigit()
                    .foregroundStyle(warn ? Theme.warning : Theme.fontQuiet).lineLimit(1)
            }
            if let share { MacServerBar(share: share, tint: warn ? Theme.warning : Theme.accent) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

private struct MacServerRing: View {
    let meter: SwiftlyCore.ServerMeter

    var body: some View {
        ZStack {
            Circle().stroke(Theme.raised, lineWidth: 10)
            Circle()
                .trim(from: 0, to: min(max(meter.share, 0), 1))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.9), value: meter.share)
            VStack(spacing: 0) {
                Text(verbatim: meter.text).font(Theme.section).monospacedDigit().foregroundStyle(Theme.font)
                Text(verbatim: meter.label).font(Theme.small).foregroundStyle(Theme.fontVeryQuiet)
            }
        }
        .frame(width: 112, height: 112)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(meter.label) \(meter.text)"))
    }
}

private struct MacServerTask: View {
    let task: SwiftlyCore.ServerTaskRow
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: task.name).font(Theme.body).foregroundStyle(Theme.font)
                Spacer(minLength: 8)
                if let text = task.progressText {
                    Text(verbatim: text).font(Theme.tile).monospacedDigit().foregroundStyle(Theme.fontQuiet)
                }
                Button(action: stop) {
                    Image(icon: "xmark.circle", size: 18).font(.app(size: 18)).foregroundStyle(Theme.fontQuiet)
                        .frame(width: 32, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressButton())
                .accessibilityIdentifier("server-stop-task")
            }
            MacServerBar(share: task.progress ?? 0, tint: Theme.accent)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// One session that is playing now: poster, title, who and on what, progress and how it is delivered.
private struct MacServerStream: View {
    let model: AppModel
    let stream: SwiftlyCore.ServerStreamCard

    var body: some View {
        HStack(spacing: 0) {
            NetworkImage(url: model.posterURL(itemID: stream.posterId, mark: stream.posterTag),
                         symbolText: "film", displayEdge: 84 * 2)
                .frame(width: 84)
                .frame(maxHeight: .infinity)
                .clipped()
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        (Text(verbatim: stream.title).foregroundStyle(Theme.font)
                            + Text(verbatim: stream.addition.map { "  " + $0 } ?? "")
                            .font(Theme.tile).foregroundStyle(Theme.fontVeryQuiet))
                            .font(Theme.listTitle).lineLimit(2)
                        if let sub = stream.subtitle {
                            Text(verbatim: sub).font(Theme.small).foregroundStyle(Theme.fontQuiet).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(verbatim: stream.userName).font(Theme.small).foregroundStyle(Theme.fontQuiet).lineLimit(1)
                }
                if !stream.badges.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(stream.badges.enumerated()), id: \.offset) { _, badge in
                            Text(verbatim: badge.text)
                                .font(Theme.small.weight(.semibold)).foregroundStyle(Theme.font).lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Self.tint(badge.kind), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                    }
                }
                Text(verbatim: stream.deviceLine).font(Theme.small).foregroundStyle(Theme.fontVeryQuiet).lineLimit(2)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(icon: stream.paused ? "pause.fill" : "play.fill", size: 11).font(.app(size: 11))
                        .foregroundStyle(Theme.fontQuiet)
                    Text(verbatim: stream.timeLine).font(Theme.small).monospacedDigit()
                        .foregroundStyle(Theme.fontQuiet).lineLimit(1).fixedSize()
                    MacServerBar(share: stream.share, tint: Theme.fontQuiet).padding(.leading, 4)
                }
                let tone = stream.cautionary ? Theme.warning : Theme.accent
                Text(verbatim: stream.deliveryLine)
                    .font(Theme.small.weight(.semibold)).foregroundStyle(tone)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(tone.opacity(0.16), in: Capsule())
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: 126)
        .background(Theme.groupsArea)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("server-stream-\(stream.sessionId)")
    }

    private static func tint(_ kind: SwiftlyCore.ServerBadgeKind) -> Color {
        switch kind {
        case .resolution: Theme.badgeResolution
        case .range: Theme.badgeRange
        case .video: Theme.badgeVideo
        case .audio: Theme.badgeAudio
        }
    }
}

// MARK: - Log files

/// The server's log files (`ServerLogsModel`): the list, then one file at its end. The back arrow returns to the list
/// first.
struct MacServerLogsPage: View {
    let model: AppModel
    let back: () -> Void

    @State private var logs: SwiftlyCore.ServerLogsModel?

    init(model: AppModel, back: @escaping () -> Void) {
        self.model = model
        self.back = back
        _logs = State(initialValue: try? AppCore.shared.serverLogs(session: model.session))
    }

    private var state: SwiftlyCore.ServerLogsState { logs?.part.state ?? .loading }
    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }
    private var isOpen: Bool {
        if case .text = state { return true }
        return false
    }
    private var title: String {
        if case .text(let name, _) = state { return name }
        return logs?.part.title ?? ""
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SubpageHeader(name: title) { if isOpen { logs?.send(.back) } else { back() } }
                    content
                        .opacity(isLoading ? 0 : 1)
                        .animation(Theme.reveal, value: isLoading)
                        .padding(.top, 18)
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: Theme.readWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.edgeSpacing)
                .padding(.top, Theme.contentTop)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.never)
            .pagesScroll()
            .onChange(of: isOpen) { _, open in if open { proxy.scrollTo("end", anchor: .bottom) } }
        }
        .accessibilityIdentifier("server-logs-page")
        .task { await logs?.run() }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading:
            Color.clear.frame(height: 400)
        case .files(let rows):
            RowsGroup {
                ForEach(Array(rows.enumerated()), id: \.element.name) { i, row in
                    if i > 0 { GroupLine() }
                    Button { logs?.send(.open(name: row.name)) } label: {
                        ValuesRow(symbol: "doc.text", title: Text(verbatim: row.name),
                                  under: Text(verbatim: [row.day, row.sizeText].compactMap { $0 }.joined(separator: " · ")),
                                  arrow: true, hoverable: true)
                    }
                    .buttonStyle(Theme.PressRow())
                }
            }
        case .empty(let hint), .failed(let hint):
            Text(verbatim: hint).font(Theme.body).foregroundStyle(Theme.fontQuiet)
                .multilineTextAlignment(.center).padding(.top, 120).frame(maxWidth: .infinity)
        case .text(_, let text):
            Text(verbatim: text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.fontQuiet)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
