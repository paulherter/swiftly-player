import SwiftUI
import SwiftlyCore

// The admin sections of the Verwaltung hub on the TV: "Meldungen" (problems) and "Server". The state and every word
// come from the core (`SeerrAdminFlow`, `ServerAdminModel`, `ServerLogsModel`), the same ones the iPhone and the Mac
// draw; this file only lays them out for the remote: every row is a focus target, Menu leaves a sub-view (thread,
// log, question) first and the hub after it.

// MARK: - Problems

struct TVAdminIssues: View {
    let model: AppModel

    @State private var flow = SeerrAdminFlow()
    @State private var openId: Int64?
    /// The reply being typed, and whether it is on its way (a second press must not send it twice).
    @State private var reply = ""
    @State private var sending = false
    @FocusState private var focusedVerb: Int?

    var body: some View {
        // A stack, not a `Group`: the content is empty until the first answer, and a modifier on an empty view never appears, so its `.task` never ran.
        VStack(alignment: .leading, spacing: 0) {
            if let openId {
                thread(openId)
            } else {
                list
            }
        }
        .opacity(flow.settled ? 1 : 0)
        .animation(Theme.reveal, value: flow.settled)
        .task { await flow.load(model) }
    }

    @ViewBuilder private var list: some View {
        if let info = flow.issues {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        ForEach(info.pills, id: \.pill) { pill in
                            Button { flow.selectIssuePill(pill.pill) } label: {
                                Text(verbatim: "\(pill.title) \(pill.count)").font(Theme.body)
                                    .padding(.horizontal, 26).padding(.vertical, 10)
                            }
                            .buttonStyle(HubTabStyle(selected: pill.selected))
                        }
                    }
                    .focusSection()
                    .padding(.bottom, 12)
                    if info.rows.isEmpty {
                        EmptyState(symbol: "checkmark.circle", title: "Keine Meldungen",
                                   hint: "Was beim Schauen nicht stimmt, steht hier.")
                            .frame(maxWidth: .infinity, minHeight: 360)
                    }
                    ForEach(info.rows) { row in
                        Button {
                            openId = row.id
                            Task { await flow.openIssue(row.id) }
                        } label: { IssueRowView(row: row) }
                            .buttonStyle(HubRowStyle())
                    }
                }
                .padding(.bottom, 80)
            }
            .scrollClipDisabled()
        } else if flow.settled {
            EmptyState(symbol: "tray", title: "Keine Meldungen", hint: "Was beim Schauen nicht stimmt, steht hier.")
        }
    }

    @ViewBuilder private func thread(_ id: Int64) -> some View {
        if let detail = flow.issue, detail.row.id == id {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: detail.row.title).font(Theme.rail).foregroundStyle(Theme.font).lineLimit(2)
                    Text(verbatim: [detail.row.kindWord, detail.row.place, detail.row.timeText].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.body).foregroundStyle(Theme.fontQuiet)
                    Text(verbatim: [detail.row.statusWord, detail.row.reporter].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.body).foregroundStyle(detail.row.isOpen ? Theme.warning : Theme.fontVeryQuiet)
                    // The verbs come first: the remote lands on them, the thread reads below.
                    HStack(spacing: 20) {
                        if detail.canResolve {
                            verb("Erledigt", at: 0) { Task { await flow.resolve() } }
                        }
                        if detail.canReopen {
                            verb("Wieder öffnen", at: 0) { Task { await flow.reopen() } }
                        }
                        verb("Zurück", at: 1) { closeThread() }
                    }
                    .focusSection()
                    .padding(.vertical, 14)
                    if let error = detail.error {
                        Text(verbatim: error).font(Theme.small).foregroundStyle(Theme.error)
                    }
                    // The reply: the system keyboard opens on the field (as the iPhone's reply field), "Senden" sends it.
                    if detail.canReply { replyRow }
                    ForEach(detail.messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: [message.author, message.whenText].compactMap { $0 }.joined(separator: " · "))
                                .font(Theme.small).foregroundStyle(Theme.fontVeryQuiet)
                            Text(verbatim: message.text).font(Theme.body).foregroundStyle(Theme.font)
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(.bottom, 80)
            }
            .scrollClipDisabled()
            .defaultFocus($focusedVerb, 0)
            .onExitCommand { closeThread() }
        } else {
            Color.clear.onExitCommand { closeThread() }
        }
    }

    private var replyRow: some View {
        HStack(spacing: 20) {
            InputField(placeholder: "Antwort schreiben …", text: $reply, completion: send)
                .accessibilityIdentifier("issue-reply-field")
            if !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: send) {
                    Text("Senden").font(Theme.body).padding(.horizontal, 32).padding(.vertical, 14)
                }
                .buttonStyle(HubTabStyle(selected: false))
                .accessibilityIdentifier("issue-reply-send")
                .transition(.opacity)
            }
        }
        .focusSection()
        .animation(Theme.focusAnimation, value: reply.isEmpty)
        .padding(.bottom, 10)
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

    private func verb(_ title: LocalizedStringKey, at index: Int, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.body).padding(.horizontal, 32).padding(.vertical, 14)
        }
        .buttonStyle(HubTabStyle(selected: false))
        .focused($focusedVerb, equals: index)
    }

    private func closeThread() {
        reply = ""
        flow.closeIssue()
        openId = nil
    }
}

private struct IssueRowView: View {
    let row: SwiftlyCore.SeerrIssueRow

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            Picture(url: row.poster.flatMap { URL(string: $0) }, width: 80, height: 120, symbolText: "film")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: row.title).font(Theme.rail).foregroundStyle(Theme.font).lineLimit(1)
                Text(verbatim: [row.kindWord, row.place, row.timeText].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.body).foregroundStyle(Theme.fontVeryQuiet).lineLimit(1)
                Text(verbatim: [row.statusWord, row.reporter].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.body).foregroundStyle(row.isOpen ? Theme.warning : Theme.fontVeryQuiet).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Server

struct TVServerAdmin: View {
    let model: AppModel

    @State private var admin: SwiftlyCore.ServerAdminModel?
    @State private var logsOpen = false
    @State private var streamMessage = ""
    @FocusState private var cancelFocused: Bool

    init(model: AppModel) {
        self.model = model
        _admin = State(initialValue: try? AppCore.shared.serverAdmin(session: model.session))
    }

    private var state: SwiftlyCore.ServerAdminState { admin?.part.state ?? .loading }

    private var ask: SwiftlyCore.ServerAdminAsk {
        if case .ready(let page) = state { return page.ask }
        return .nothing
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if logsOpen {
                    TVServerLogs(model: model) { logsOpen = false }
                } else {
                    content
                }
            }
            .disabled(ask != .nothing)
            if ask != .nothing { question }
        }
        .opacity(isLoading ? 0 : 1)
        .animation(Theme.reveal, value: isLoading)
        .animation(Theme.reveal, value: ask != .nothing)
        .task { await admin?.run() }
        .onChange(of: ask) { _, next in
            if next != .nothing {
                if case .stopStream(_, _, _, _, let text, _) = next { streamMessage = text }
                cancelFocused = true
            }
        }
    }

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading:
            Color.clear
        case .ready(let page):
            body(of: page)
        case .failed(let hint):
            VStack(spacing: 24) {
                Text(verbatim: hint).font(Theme.body).foregroundStyle(Theme.fontQuiet).multilineTextAlignment(.center)
                Button { admin?.send(.retry) } label: {
                    Text("Nochmal").font(Theme.body).padding(.horizontal, 32).padding(.vertical, 14)
                }
                .buttonStyle(HubTabStyle(selected: false))
            }
            .frame(maxWidth: .infinity).padding(.top, 120)
        case .notAllowed(let hint):
            Text(verbatim: hint).font(Theme.body).foregroundStyle(Theme.fontQuiet)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 120)
        }
    }

    private func body(of page: SwiftlyCore.ServerAdminPage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                (Text(verbatim: page.name).foregroundStyle(Theme.font)
                    + Text(verbatim: page.version.isEmpty ? "" : "  \(page.version)").foregroundStyle(Theme.fontVeryQuiet))
                    .font(Theme.rail).lineLimit(1)
                Text(verbatim: page.counts.map { "\($0.text) \($0.label)" }.joined(separator: "   "))
                    .font(Theme.body).foregroundStyle(Theme.fontQuiet).lineLimit(1)
                // Actions first: the remote lands on them, the long lists follow below.
                VStack(spacing: 8) {
                    ForEach(Array(page.actions.enumerated()), id: \.offset) { _, action in
                        TVServerRow(title: action.title, under: action.under, chevron: action.kind == .logs) {
                            switch action.kind {
                            case .scanLibraries: admin?.send(.scan)
                            case .restart: admin?.send(.askRestart)
                            case .logs: logsOpen = true
                            }
                        }
                    }
                }
                .focusSection()
                .padding(.top, 14)
                if let load = page.load {
                    group(page.loadTitle)
                    ForEach([load.cpu, load.memory].compactMap { $0 }, id: \.label) { meter in
                        line(meter.label, meter.text)
                    }
                    if let io = load.diskIo { line(io.label, io.text) }
                    ForEach(page.disks, id: \.id) { line($0.title, $0.freeText) }
                }
                if !page.tasks.isEmpty {
                    group(page.tasksTitle)
                    ForEach(page.tasks, id: \.id) { task in
                        TVServerRow(title: task.name, under: task.progressText, chevron: false) { admin?.send(.askStopTask(id: task.id)) }
                    }
                }
                group(page.streamsTitle)
                if page.streams.isEmpty {
                    Text(verbatim: page.streamsEmpty).font(Theme.body).foregroundStyle(Theme.fontVeryQuiet)
                }
                ForEach(page.streams, id: \.id) { stream in
                    TVServerRow(title: [stream.title, stream.addition].compactMap { $0 }.joined(separator: " · "),
                                under: "\(stream.userName) · \(stream.timeLine)", chevron: false) {
                        admin?.send(.askStopStream(sessionId: stream.sessionId))
                    }
                }
                if let note = page.notice {
                    Text(verbatim: note).font(Theme.small).foregroundStyle(Theme.fontVeryQuiet).padding(.top, 14)
                }
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
    }

    private func group(_ title: String) -> some View {
        Text(verbatim: title).font(Theme.small).foregroundStyle(Theme.fontVeryQuiet).padding(.top, 22)
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack {
            Text(verbatim: label).font(Theme.body).foregroundStyle(Theme.font)
            Spacer(minLength: 24)
            Text(verbatim: value).font(Theme.body).foregroundStyle(Theme.fontQuiet)
        }
    }

    /// The core's question over the page. **The cancel button takes the first focus**: a stray select never restarts
    /// the server or ends a stream. Menu cancels as well.
    private var question: some View {
        let (title, note, action): (String, String?, String) = switch ask {
        case .restart(let title, let note, let action): (title, note, action)
        case .stopTask(_, let title, let action): (title, nil, action)
        case .stopStream(_, let title, let line, _, _, let action): (title, line, action)
        case .nothing: ("", nil, "")
        }
        return ZStack {
            Theme.reason.opacity(0.92).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Text(verbatim: title).font(Theme.rail).foregroundStyle(Theme.font)
                if let note { Text(verbatim: note).font(Theme.body).foregroundStyle(Theme.fontQuiet) }
                if case .stopStream(_, _, _, let label, _, _) = ask {
                    Text(verbatim: label).font(Theme.small).foregroundStyle(Theme.fontVeryQuiet)
                    TextField("", text: $streamMessage).font(Theme.body)
                }
                HStack(spacing: 20) {
                    Button { admin?.send(.cancel) } label: {
                        Text("Abbrechen").font(Theme.body).padding(.horizontal, 32).padding(.vertical, 14)
                    }
                    .buttonStyle(HubTabStyle(selected: false))
                    .focused($cancelFocused)
                    Button {
                        if case .stopStream = ask { admin?.send(.confirm(message: streamMessage)) } else { admin?.send(.confirm(message: nil)) }
                    } label: {
                        Text(verbatim: action).font(Theme.body).padding(.horizontal, 32).padding(.vertical, 14)
                    }
                    .buttonStyle(HubTabStyle(selected: false))
                }
                .focusSection()
            }
            .padding(48)
            .frame(maxWidth: 1100, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(Theme.area))
            .defaultFocus($cancelFocused, true)
        }
        .onExitCommand { admin?.send(.cancel) }
        .transition(.opacity)
        .onAppear { cancelFocused = true }
    }
}

private struct TVServerRow: View {
    let title: String
    var under: String?
    var chevron = true
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: title).font(Theme.body).foregroundStyle(Theme.font).lineLimit(1)
                    if let under { Text(verbatim: under).font(Theme.small).foregroundStyle(Theme.fontVeryQuiet).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if chevron { Image(icon: "chevron.right").font(.app(size: 24, weight: .semibold)).foregroundStyle(Theme.fontQuiet) }
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(HubRowStyle())
    }
}

// MARK: - Log files

/// The server's log files: the list, then one file at its end. Menu returns from a file to the list, then closes.
struct TVServerLogs: View {
    let model: AppModel
    let close: () -> Void

    @State private var logs: SwiftlyCore.ServerLogsModel?

    init(model: AppModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        _logs = State(initialValue: try? AppCore.shared.serverLogs(session: model.session))
    }

    private var state: SwiftlyCore.ServerLogsState { logs?.part.state ?? .loading }

    var body: some View {
        Group {
            switch state {
            case .loading:
                Color.clear
            case .files(let rows):
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(rows, id: \.name) { row in
                            TVServerRow(title: row.name, under: [row.day, row.sizeText].compactMap { $0 }.joined(separator: " · ")) {
                                logs?.send(.open(name: row.name))
                            }
                        }
                    }
                    .padding(.bottom, 80)
                }
                .scrollClipDisabled()
            case .empty(let hint), .failed(let hint):
                Text(verbatim: hint).font(Theme.body).foregroundStyle(Theme.fontQuiet)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 120)
            case .text(let name, let text):
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(verbatim: name).font(Theme.rail).foregroundStyle(Theme.font)
                            Text(verbatim: String(text.suffix(6000)))
                                .font(.system(size: 22, design: .monospaced))
                                .foregroundStyle(Theme.fontQuiet)
                            Color.clear.frame(height: 1).id("end")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .focusable()
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .task { await logs?.run() }
        .onExitCommand {
            if case .text = state { logs?.send(.back) } else { close() }
        }
    }
}
