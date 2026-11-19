import JellyfinKit
import SwiftUI
import SwiftlyCore

// MARK: - Profile row

/// The one Profile row for requests, reports and the server. Shown only when the core lists an entry; every word is
/// the core's (`profileEntry`), the count mark is what waits for a manager.
struct ManagementEntryRow: View {
    let entry: SwiftlyCore.ProfileEntry

    var body: some View {
        NavigationLink(value: ManagementHubRoute(entry)) {
            ServerRowShell(symbol: entry.kind == .admin ? "speedometer" : "arrow.down.circle",
                           title: entry.title, under: entry.under, count: entry.kind == .admin ? Int(entry.count) : 0,
                           last: true)
        }
        .buttonStyle(Theme.PressRow())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("profile-management")
    }
}

/// One flat row: symbol, title with an optional second line, chevron or nothing. Words are the core's, never looked up.
private struct ServerRowShell: View {
    let symbol: String
    let title: String
    var under: String?
    var accent = false
    var chevron = true
    var count = 0
    var last = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(icon: symbol, size: Theme.rowSymbolSize)
                    .font(.app(size: Theme.rowSymbolSize))
                    .frame(width: Theme.rowIconWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.app(size: Theme.rowTitleSize, weight: .medium))
                    if let under {
                        Text(verbatim: under)
                            .font(Theme.small)
                            .foregroundStyle(accent ? Theme.warning : Theme.fontVeryQuiet)
                    }
                }
                Spacer(minLength: 0)
                if count > 0 { SeerrCountMark(count: count) }
                if chevron {
                    Image(icon: "chevron.right", size: 13)
                        .font(.app(size: 13, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(accent ? Theme.warning : Theme.font)
            .padding(.horizontal, 16)
            .padding(.vertical, Theme.rowPadV)
            .frame(minHeight: Theme.rowHeight)
            if !last { SheetLine() }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - The page

/// **Server management** (the "Server" section of Profile > Verwaltung): what the server is, what runs on it and who is
/// watching, with scan, restart and the log files. Nothing is decided here: the core's `ServerAdminVm` hands over every
/// word and number, the confirm questions and the one-second refresh; the page forwards taps and draws `part`.
///
/// **Complete when it appears.** Until the first answer is in the page is empty and invisible, then it comes in as one
/// piece; cards are keyed by session so a refresh never reloads a poster. The refresh runs only while the page is on
/// screen (`run()` sends Start, and Stop when the task is cancelled).
struct ServerAdminView: View {
    let model: AppModel

    @Environment(\.wide) private var wide
    @State private var admin: SwiftlyCore.ServerAdminModel?
    @State private var askOpen = false
    @State private var shownAsk: SwiftlyCore.ServerAdminAsk = .nothing
    @State private var streamMessage = ""

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

    /// The section's content only: the hub owns the page, its header and the scrolling.
    var body: some View {
        content
            .opacity(isReady ? 1 : 0)
            .animation(Theme.reveal, value: isReady)
            .hubSheet(id: "server-ask") {
                ServerAskSheet(opened: $askOpen, ask: shownAsk, message: $streamMessage) { answer in
                    admin?.send(.confirm(message: answer))
                }
            }
        .onChange(of: ask) { _, next in
            if next != .nothing {
                shownAsk = next
                if case .stopStream(_, _, _, _, let text, _) = next { streamMessage = text }
                askOpen = true
            } else {
                askOpen = false
            }
        }
        .onChange(of: askOpen) { _, open in
            // A swipe or the cancel row closed it: tell the core, so it asks again next time and sends nothing.
            if !open, ask != .nothing { admin?.send(.cancel) }
        }
        .task { await admin?.run() }
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
            Text(verbatim: hint)
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .multilineTextAlignment(.center)
            if retry {
                ValuePill(symbol: "arrow.clockwise", text: String(localized: "Nochmal")) { admin?.send(.retry) }
            }
        }
        .padding(.horizontal, Theme.margin(wide: wide))
        .padding(.top, 160)
        .frame(maxWidth: .infinity)
    }

    private func pageBody(_ page: SwiftlyCore.ServerAdminPage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // **One block for what the server is and what it holds**, then what moves (tasks, streams), the load
            // last: it matters only when something above looks slow.
            ServerGroup(title: page.serverTitle) { serverCard(page) }
            if !page.tasks.isEmpty {
                ServerGroup(title: page.tasksTitle) {
                    ForEach(Array(page.tasks.enumerated()), id: \.element.id) { i, task in
                        ServerTaskView(task: task) { admin?.send(.askStopTask(id: task.id)) }
                        if i < page.tasks.count - 1 { SheetLine() }
                    }
                }
            }
            streams(page)
            if page.load != nil || !page.disks.isEmpty {
                ServerGroup(title: page.loadTitle) { loadCard(page) }
            }
            ServerGroup(title: page.actionsTitle) {
                ForEach(Array(page.actions.enumerated()), id: \.offset) { i, action in
                    actionRow(action, last: i == page.actions.count - 1)
                }
            }
            if let text = page.notice {
                Footer(Text(verbatim: text))
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.top, 12)
            }
        }
        .padding(.bottom, 40)
        .frame(maxWidth: wide ? Theme.readWidth : .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func serverCard(_ page: SwiftlyCore.ServerAdminPage) -> some View {
        VStack(spacing: 0) {
            (Text(verbatim: page.name).foregroundStyle(Theme.font)
                + Text(verbatim: page.version.isEmpty ? "" : "  \(page.version)").foregroundStyle(Theme.fontVeryQuiet))
                .font(Theme.listTitle)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            if !page.counts.isEmpty {
                SheetLine()
                ServerNumbers(entries: page.counts)
            }
            if !page.resolutions.isEmpty {
                SheetLine()
                ServerNumbers(entries: page.resolutions)
            }
        }
    }

    @ViewBuilder private func streams(_ page: SwiftlyCore.ServerAdminPage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupsTitle(verbatim: page.streamsTitle)
                .padding(.horizontal, Theme.margin(wide: wide) - Theme.edgeSpacing)
                .padding(.top, Theme.groupTop)
                .padding(.bottom, 2)
            if page.streams.isEmpty {
                Text(verbatim: page.streamsEmpty)
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.top, 6)
            }
            // **A tap on a card asks about stopping it**, with a message to the viewer: the one thing an administrator
            // does about someone else's stream. Keyed by the core's id (session and title), so the 1 s refresh keeps
            // every card, and its poster, where it is.
            ForEach(page.streams, id: \.id) { stream in
                Button { admin?.send(.askStopStream(sessionId: stream.sessionId)) } label: {
                    ServerStreamView(model: model, stream: stream)
                }
                .buttonStyle(Theme.PressButton())
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.top, 10)
            }
        }
        .animation(Theme.reveal, value: page.streams.map(\.id))
    }

    private func loadCard(_ page: SwiftlyCore.ServerAdminPage) -> some View {
        VStack(spacing: 0) {
            if let load = page.load {
                if load.cpu != nil || load.memory != nil {
                    HStack(spacing: 28) {
                        if let cpu = load.cpu { ServerRing(meter: cpu) }
                        if let memory = load.memory { ServerRing(meter: memory) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                }
                if let io = load.diskIo {
                    if load.cpu != nil || load.memory != nil { SheetLine() }
                    ServerMeterRow(title: io.label, value: io.text, share: nil)
                }
                if !page.disks.isEmpty { SheetLine() }
            }
            ForEach(Array(page.disks.enumerated()), id: \.element.id) { i, disk in
                ServerMeterRow(title: disk.title, value: disk.freeText, share: disk.freeShare, warn: disk.nearlyFull)
                if i < page.disks.count - 1 { SheetLine() }
            }
        }
    }

    @ViewBuilder private func actionRow(_ action: SwiftlyCore.ServerAction, last: Bool) -> some View {
        let symbol = switch action.kind {
        case .scanLibraries: "arrow.triangle.2.circlepath"
        case .restart: "arrow.clockwise"
        case .logs: "doc.text"
        }
        let shell = ServerRowShell(
            symbol: symbol, title: action.title, under: action.under, accent: action.accent,
            chevron: action.kind == .logs, last: last)
        switch action.kind {
        case .logs:
            NavigationLink(value: ServerLogsRoute()) { shell }
                .buttonStyle(Theme.PressRow())
                .accessibilityIdentifier("server-logs")
        case .scanLibraries:
            Button { Theme.jerk(.lightweight); admin?.send(.scan) } label: { shell }
                .buttonStyle(Theme.PressRow())
                .accessibilityIdentifier("server-scan")
        case .restart:
            Button { admin?.send(.askRestart) } label: { shell }
                .buttonStyle(Theme.PressRow())
                .accessibilityIdentifier("server-restart")
        }
    }
}

// MARK: - Parts

/// A titled card group with the core's words (the same look as `SettingGroup`, whose title is a looked-up key).
private struct ServerGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @Environment(\.wide) private var wide

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupsTitle(verbatim: title)
                .padding(.horizontal, Theme.margin(wide: wide) - Theme.edgeSpacing)
                .padding(.top, Theme.groupTop)
                .padding(.bottom, 2)
            CardView { content() }
        }
    }
}

private struct ServerNumbers: View {
    let entries: [SwiftlyCore.ServerNumber]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(entries, id: \.label) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.text)
                        .font(Theme.rail)
                        .monospacedDigit()
                        .foregroundStyle(Theme.font)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(verbatim: entry.label)
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}

private struct ServerMeterRow: View {
    let title: String
    let value: String
    let share: Double?
    var warn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: title)
                    .font(.app(size: Theme.rowTitleSize, weight: .medium))
                    .foregroundStyle(Theme.font)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: value)
                    .font(Theme.tile)
                    .monospacedDigit()
                    .foregroundStyle(warn ? Theme.warning : Theme.fontQuiet)
                    .lineLimit(1)
            }
            if let share { ServerBar(share: share, tint: warn ? Theme.warning : Theme.accent) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// A 4 pt bar. It glides to the next value over almost the refresh interval, so a one-second refresh reads as motion.
private struct ServerBar: View {
    let share: Double
    let tint: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.margin)
                Capsule().fill(tint)
                    .frame(width: g.size.width * min(max(share, 0), 1))
            }
        }
        .frame(height: 4)
        .animation(.linear(duration: 0.9), value: share)
    }
}

private struct ServerRing: View {
    let meter: SwiftlyCore.ServerMeter

    private let size: CGFloat = 112
    private let line: CGFloat = 10

    var body: some View {
        ZStack {
            Circle().stroke(Theme.raised, lineWidth: line)
            Circle()
                .trim(from: 0, to: min(max(meter.share, 0), 1))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.9), value: meter.share)
            VStack(spacing: 0) {
                Text(verbatim: meter.text)
                    .font(Theme.section)
                    .monospacedDigit()
                    .foregroundStyle(Theme.font)
                Text(verbatim: meter.label)
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(meter.label) \(meter.text)"))
    }
}

private struct ServerTaskView: View {
    let task: SwiftlyCore.ServerTaskRow
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: task.name)
                    .font(.app(size: Theme.rowTitleSize, weight: .medium))
                    .foregroundStyle(Theme.font)
                Spacer(minLength: 8)
                if let text = task.progressText {
                    Text(verbatim: text).font(Theme.tile).monospacedDigit().foregroundStyle(Theme.fontQuiet)
                }
                Button(action: stop) {
                    Image(icon: "xmark.circle", size: 20)
                        .font(.app(size: 20))
                        .foregroundStyle(Theme.fontQuiet)
                        .frame(width: 44, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Theme.PressText())
                .accessibilityIdentifier("server-stop-task")
            }
            ServerBar(share: task.progress ?? 0, tint: Theme.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// One session that is playing now: poster, title, who and on what, progress and how it is delivered.
private struct ServerStreamView: View {
    let model: AppModel
    let stream: SwiftlyCore.ServerStreamCard

    private let posterWidth: CGFloat = 84

    var body: some View {
        HStack(spacing: 0) {
            NetworkImage(
                url: model.posterURL(itemID: stream.posterId, mark: stream.posterTag),
                symbolText: "film", displayEdge: posterWidth * 1.5)
                .frame(width: posterWidth)
                .frame(maxHeight: .infinity)
                .clipped()
            VStack(alignment: .leading, spacing: 8) {
                heading
                if !stream.badges.isEmpty { badges }
                Text(verbatim: stream.deviceLine)
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .lineLimit(2)
                Spacer(minLength: 0)
                progress
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // As tall as the text needs; the poster takes that whole height.
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: posterWidth * 1.5)
        .background(Theme.groupsArea)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("server-stream-\(stream.sessionId)")
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                (Text(verbatim: stream.title).foregroundStyle(Theme.font)
                    + Text(verbatim: stream.addition.map { "  " + $0 } ?? "")
                    .font(Theme.tile).foregroundStyle(Theme.fontVeryQuiet))
                    .font(Theme.listTitle)
                    .lineLimit(2)
                if let sub = stream.subtitle {
                    Text(verbatim: sub).font(Theme.small).foregroundStyle(Theme.fontQuiet).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            user
        }
    }

    private var user: some View {
        HStack(spacing: 5) {
            ZStack {
                Theme.raised
                Text(verbatim: String(stream.userName.prefix(1)).uppercased())
                    .font(Theme.small)
                    .foregroundStyle(Theme.font)
                if let id = stream.userId, stream.userImageTag != nil {
                    NetworkImage(url: model.userImageURL(userID: id, edge: 60), displayEdge: 20)
                }
            }
            .frame(width: 20, height: 20)
            .clipShape(Circle())
            Text(verbatim: stream.userName)
                .font(Theme.small)
                .foregroundStyle(Theme.fontQuiet)
                .lineLimit(1)
        }
    }

    private var badges: some View {
        HStack(spacing: 5) {
            ForEach(Array(stream.badges.enumerated()), id: \.offset) { _, badge in
                Text(verbatim: badge.text)
                    .font(Theme.small.weight(.semibold))
                    .foregroundStyle(Theme.font)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Self.tint(badge.kind), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
    }

    private static func tint(_ kind: SwiftlyCore.ServerBadgeKind) -> Color {
        switch kind {
        case .resolution: Theme.badgeResolution
        case .range: Theme.badgeRange
        case .video: Theme.badgeVideo
        case .audio: Theme.badgeAudio
        }
    }

    private var progress: some View {
        // A transcode is the warning colour: it is what loads the server.
        let tone = stream.cautionary ? Theme.warning : Theme.accent
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(icon: stream.paused ? "pause.fill" : "play.fill", size: 11)
                    .font(.app(size: 11))
                    .foregroundStyle(Theme.fontQuiet)
                Text(verbatim: stream.timeLine)
                    .font(Theme.small)
                    .monospacedDigit()
                    .foregroundStyle(Theme.fontQuiet)
                    .lineLimit(1)
                    .fixedSize()
                ServerBar(share: stream.share, tint: Theme.fontQuiet)
                    .padding(.leading, 4)
            }
            Text(verbatim: stream.deliveryLine)
                .font(Theme.small.weight(.semibold))
                .foregroundStyle(tone)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(tone.opacity(0.16), in: Capsule())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

// MARK: - The confirm question

/// **The core's question as a sheet** (restart, stop a task, stop a stream). The core decides what is asked and with which
/// words; the sheet only shows it. "Stop a stream" carries a message to the viewer, started with the core's default.
private struct ServerAskSheet: View {
    @Binding var opened: Bool
    let ask: SwiftlyCore.ServerAdminAsk
    @Binding var message: String
    /// The answer: the viewer's message for a stream, otherwise `nil`.
    let confirm: (String?) -> Void

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .sheet(opened: $opened) {
                switch ask {
                case .nothing:
                    EmptyView()
                case .restart(let title, let note, let action):
                    heading(title, note: note)
                    answer(action, symbol: "arrow.clockwise", id: "restart-confirm") { confirm(nil) }
                case .stopTask(_, let title, let action):
                    heading(title, note: nil)
                    answer(action, symbol: "xmark.circle", id: "stop-task-confirm") { confirm(nil) }
                case .stopStream(_, let title, let line, let label, _, let action):
                    heading(title, note: line)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: label)
                            .font(Theme.small)
                            .foregroundStyle(Theme.fontQuiet)
                        TextField("", text: $message, axis: .vertical)
                            .font(Theme.body)
                            .lineLimit(2...4)
                            .foregroundStyle(Theme.font)
                            .padding(12)
                            .background(Theme.area, in: RoundedRectangle(cornerRadius: Theme.cornerField, style: .continuous))
                            .accessibilityIdentifier("stop-stream-message")
                    }
                    .padding(.horizontal, Theme.edgeSpacing)
                    .padding(.bottom, 14)
                    answer(action, symbol: "xmark.circle", id: "stop-stream-confirm") { confirm(message) }
                }
            }
    }

    @ViewBuilder private func heading(_ title: String, note: String?) -> some View {
        SheetCategory(text: Text(verbatim: title))
        if let note {
            Text(verbatim: note)
                .font(Theme.small)
                .foregroundStyle(Theme.fontQuiet)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.edgeSpacing)
                .padding(.bottom, 14)
        }
    }

    @ViewBuilder private func answer(_ title: String, symbol: String, id: String, perform: @escaping () -> Void) -> some View {
        SheetLine()
        Button {
            opened = false
            perform()
        } label: {
            HStack(spacing: 14) {
                Image(icon: symbol, size: 17)
                    .font(.app(size: 17))
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(verbatim: title).font(.app(size: 17))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.warning)
            .padding(.horizontal, Theme.edgeSpacing)
            .frame(minHeight: Theme.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressRow())
        .accessibilityIdentifier(id)
        SheetLine()
        SheetCancel { opened = false }
    }
}

// MARK: - Log files

/// **The server's log files** (`ServerLogsVm`): the list, then one file at its end. The core words every state; a file
/// opens in place and the back arrow returns to the list first.
struct ServerLogsView: View {
    let model: AppModel

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @State private var logs: SwiftlyCore.ServerLogsModel?

    init(model: AppModel) {
        self.model = model
        _logs = State(initialValue: try? AppCore.shared.serverLogs(session: model.session))
    }

    private var state: SwiftlyCore.ServerLogsState { logs?.part.state ?? .loading }

    private var isOpen: Bool {
        if case .text = state { return true }
        return false
    }

    private var title: String {
        if case .text(let name, _) = state { return name }
        return logs?.part.title ?? ""
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView {
                    content
                        .opacity(isLoading ? 0 : 1)
                        .animation(Theme.reveal, value: isLoading)
                    Color.clear.frame(height: 1).id("end")
                }
                .scrollIndicators(.hidden)
                .onChange(of: isOpen) { _, open in if open { proxy.scrollTo("end", anchor: .bottom) } }
            }
            .fadingUnderSubpageHeader(title: title) {
                if isOpen { logs?.send(.back) } else { back() }
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
        .task { await logs?.run() }
    }

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading:
            Color.clear.frame(height: 600)
        case .files(let rows):
            CardView {
                ForEach(Array(rows.enumerated()), id: \.element.name) { i, row in
                    Button { logs?.send(.open(name: row.name)) } label: { fileRow(row, last: i == rows.count - 1) }
                        .buttonStyle(Theme.PressRow())
                }
            }
            .padding(.top, 18)
            .padding(.bottom, 40)
            .frame(maxWidth: wide ? Theme.readWidth : .infinity)
            .frame(maxWidth: .infinity)
        case .empty(let hint), .failed(let hint):
            Text(verbatim: hint)
                .font(Theme.body)
                .foregroundStyle(Theme.fontQuiet)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.top, 160)
                .frame(maxWidth: .infinity)
        case .text(_, let text):
            Text(verbatim: text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.fontQuiet)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.top, 18)
                .padding(.bottom, 40)
        }
    }

    private func fileRow(_ row: SwiftlyCore.ServerLogRow, last: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.name)
                        .font(.app(size: Theme.rowTitleSize, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: [row.day, row.sizeText].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontVeryQuiet)
                }
                Spacer(minLength: 0)
                Image(icon: "chevron.right", size: 13)
                    .font(.app(size: 13, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Theme.font)
            .padding(.horizontal, 16)
            .padding(.vertical, Theme.rowPadV)
            .frame(minHeight: Theme.rowHeight)
            if !last { SheetLine() }
        }
        .contentShape(Rectangle())
    }
}
