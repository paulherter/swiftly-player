import JellyfinKit
import SwiftUI

/// **The server, for its administrator**: what it is, what it holds, how loaded it is, what
/// runs and who plays what, with restart, library scan and the log at the bottom.
///
/// iPhone and iPad only: the administrator checks on the server from the sofa or on the way;
/// the TV is what plays, and the Mac has the server's own web dashboard a click away.
///
/// **Two speeds** (``ServerAdministration``): the library counts once when the page opens,
/// everything else every second. A stream card keeps its identity (session and title), so the
/// poster and badges stay while only time, bar and pause move.
struct ServerDashboardView: View {
    let model: AppModel

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide

    @State private var once: (system: ServerSystem, counts: ServerCounts, resolutions: ResolutionCounts?)?
    @State private var live = ServerLive()
    @State private var failure: String?
    @State private var restartSheet = false
    @State private var notice: String?

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            ScrollView { content.padding(.top, -Theme.firstGroupTrim) }
                .scrollIndicators(.hidden)
                .fadingUnderSubpageHeader(title: once?.system.name ?? String(localized: "Server")) { back() }
        }
        .overlay(alignment: .topTrailing) {
            ActionSheet(opened: $restartSheet,
                        title: String(localized: "Server neu starten?"),
                        actions: [
                TitleAction(symbol: "arrow.clockwise", text: "Neu starten", cautionary: true) { restart() },
            ], note: "Wer gerade schaut, wird für eine Minute unterbrochen.")
        }
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        .task { await load() }
    }

    // MARK: Loading

    private func load() async {
        guard let admin = model.administration else { return }
        do {
            once = try await admin.dashboardOnce()
            failure = nil
        } catch {
            failure = model.readable(error)
        }
        // Every second until the page goes; `.task` cancels the loop with it.
        while !Task.isCancelled {
            let next = await admin.dashboardLive()
            if Task.isCancelled { break }
            live = next
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func restart() {
        guard let admin = model.administration else { return }
        Task {
            do {
                try await admin.restartServer()
                notice = String(localized: "Der Server startet neu.")
            } catch { notice = model.readable(error) }
        }
    }

    private func scan() {
        guard let admin = model.administration else { return }
        Task {
            do {
                try await admin.scanLibraries()
                notice = String(localized: "Die Mediathek wird gescannt.")
            } catch { notice = model.readable(error) }
        }
    }

    // MARK: Page

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let failure {
                Text(failure)
                    .font(Theme.body)
                    .foregroundStyle(Theme.error)
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.top, Theme.groupTop)
            }
            // **One block for what the server is and what it holds**: name and version, then the
            // counts. Then what moves: tasks, streams, and the load last, which matters only when
            // something above it looks slow.
            if let once {
                SettingGroup(title: "Server") { serverCard(once) }
            }
            if !live.tasks.isEmpty {
                SettingGroup(title: "Aufgaben") {
                    ForEach(Array(live.tasks.enumerated()), id: \.element.id) { i, task in
                        TaskRow(task: task)
                        if i < live.tasks.count - 1 { SheetLine() }
                    }
                }
            }
            streams
            if live.load != nil || !live.disks.isEmpty {
                SettingGroup(title: "Auslastung") { loadCard }
            }
            SettingGroup(title: "Verwaltung") {
                ProfileRow(symbol: "arrow.triangle.2.circlepath", title: "Mediathek scannen",
                           under: "Alle Bibliotheken nach neuen Dateien durchsuchen", trailing: .none) { scan() }
                ProfileRow(symbol: "arrow.clockwise", title: "Server neu starten",
                           under: once?.system.pendingRestart == true ? LocalizedStringKey("Ein Neustart steht aus") : nil,
                           accent: once?.system.pendingRestart == true,
                           trailing: .none) { restartSheet = true }
                ProfileRow(symbol: "doc.text", title: "Protokoll",
                           under: "Die Logdateien des Servers", last: true, target: ServerLogsRoute())
            }
            if let notice {
                Footer(Text(verbatim: notice))
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.top, 12)
            }
        }
        .padding(.bottom, 40)
        .frame(maxWidth: wide ? Theme.readWidth : .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func serverCard(_ once: (system: ServerSystem, counts: ServerCounts, resolutions: ResolutionCounts?)) -> some View {
        VStack(spacing: 0) {
            (Text(verbatim: once.system.name).foregroundStyle(Theme.font)
             + Text(verbatim: once.system.version.isEmpty ? "" : "  (\(once.system.version))")
                .foregroundStyle(Theme.fontVeryQuiet))
                .font(Theme.listTitle)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.margin(wide: wide))
            .padding(.vertical, 14)
            SheetLine()
            NumberRow(entries: [
                (String(localized: "Filme"), once.counts.movies),
                (String(localized: "Serien"), once.counts.series),
                (String(localized: "Folgen"), once.counts.episodes),
            ])
            if let r = once.resolutions {
                SheetLine()
                NumberRow(entries: [("4K", r.uhd), ("HD", r.hd), ("SD", r.sd)])
            }
        }
    }

    /// Two rings for processor and memory, the disks' read and write rate under them, then
    /// every drive with what is left on it.
    private var loadCard: some View {
        VStack(spacing: 0) {
            if let load = live.load {
                HStack(spacing: 28) {
                    if let cpu = load.cpuPercent { LoadRing(value: cpu, label: String(localized: "CPU")) }
                    if let memory = load.memoryPercent { LoadRing(value: memory, label: String(localized: "RAM")) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                if let io = load.diskText {
                    SheetLine()
                    MeterRow(title: String(localized: "Festplatten"), value: io, share: nil)
                }
                if !live.disks.isEmpty { SheetLine() }
            }
            ForEach(Array(live.disks.enumerated()), id: \.element.id) { i, disk in
                MeterRow(title: disk.uses.joined(separator: ", "), value: disk.freeText,
                         share: disk.freeShare, warn: disk.nearlyFull)
                if i < live.disks.count - 1 { SheetLine() }
            }
        }
    }

    @ViewBuilder private var streams: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupsTitle(text: "Wiedergaben")
                .padding(.horizontal, Theme.margin(wide: wide) - Theme.edgeSpacing)
                .padding(.top, Theme.groupTop)
                .padding(.bottom, 2)
            if live.streams.isEmpty {
                Text("Gerade spielt niemand etwas ab.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.top, 6)
            }
            ForEach(live.streams) { stream in
                StreamCard(model: model, stream: stream)
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.top, 10)
            }
        }
        .animation(Theme.reveal, value: live.streams.map(\.id))
    }
}

// MARK: - Parts

/// Three to five counts side by side: the number large, what it counts below.
private struct NumberRow: View {
    let entries: [(String, Int)]
    @Environment(\.wide) private var wide

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(entries, id: \.0) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.1.formatted())
                        .font(Theme.rail)
                        .monospacedDigit()
                        .foregroundStyle(Theme.font)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(verbatim: entry.0)
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Theme.margin(wide: wide))
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}

/// A name, a value on the right and, where there is a share, a bar below.
private struct MeterRow: View {
    let title: String
    let value: String
    let share: Double?
    var warn = false
    @Environment(\.wide) private var wide

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
            if let share { Bar(share: share, tint: warn ? Theme.warning : Theme.accent) }
        }
        .padding(.horizontal, Theme.margin(wide: wide))
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// A thin progress bar: track white 12 %, fill in the given tone.
private struct Bar: View {
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

/// **Load as a ring**: the share as an arc in the accent on a quiet track, the number large in
/// the middle and what it measures under it.
private struct LoadRing: View {
    let value: Double
    let label: String

    private let size: CGFloat = 112
    private let line: CGFloat = 10

    var body: some View {
        ZStack {
            Circle().stroke(Theme.raised, lineWidth: line)
            Circle()
                .trim(from: 0, to: min(max(value / 100, 0), 1))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.9), value: value)
            VStack(spacing: 0) {
                Text(verbatim: ServerLoad.percent(value))
                    .font(Theme.section)
                    .monospacedDigit()
                    .foregroundStyle(Theme.font)
                Text(verbatim: label)
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(label) \(ServerLoad.percent(value))"))
    }
}

private struct TaskRow: View {
    let task: ServerTask
    @Environment(\.wide) private var wide

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: task.name)
                        .font(.app(size: Theme.rowTitleSize, weight: .medium))
                        .foregroundStyle(Theme.font)
                    if let category = task.category {
                        Text(verbatim: category).font(Theme.small).foregroundStyle(Theme.fontVeryQuiet)
                    }
                }
                Spacer(minLength: 8)
                if let p = task.progressText {
                    Text(verbatim: p).font(Theme.tile).monospacedDigit().foregroundStyle(Theme.fontQuiet)
                }
            }
            Bar(share: (task.progress ?? 0) / 100, tint: Theme.accent)
        }
        .padding(.horizontal, Theme.margin(wide: wide))
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// **One stream**: the poster down the whole left edge; right of it the title with who
/// watches, the file's badges, the device, and at the bottom the bar with time and how the
/// server delivers it at what rate.
struct StreamCard: View {
    let model: AppModel
    let stream: ServerStream

    private let posterWidth: CGFloat = 84

    var body: some View {
        HStack(spacing: 0) {
            NetworkImage(url: model.posterURL(itemID: stream.posterID, mark: stream.posterTag),
                         symbolText: stream.isAudio ? "music.note" : "film", displayEdge: posterWidth * 1.5)
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
        // As tall as the text needs, and the poster takes that whole height.
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: posterWidth * 1.5)
        .background(Theme.groupsArea)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                (Text(verbatim: stream.title).foregroundStyle(Theme.font)
                 + Text(verbatim: stream.titleAddition.map { "  " + $0 } ?? "")
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
                if let id = stream.userID, stream.userImageTag != nil {
                    NetworkImage(url: model.userImageURL(userID: id, tag: stream.userImageTag, edge: 60),
                                 displayEdge: 20)
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
        FlowRow(spacing: 5) {
            ForEach(stream.badges, id: \.kind) { badge in
                Text(verbatim: badge.text)
                    .font(Theme.small.weight(.semibold))
                    .foregroundStyle(Theme.font)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Self.tint(badge.kind), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
    }

    static func tint(_ kind: ServerStream.Badge.Kind) -> Color {
        switch kind {
        case .resolution: Theme.badgeResolution
        case .range: Theme.badgeRange
        case .video: Theme.badgeVideo
        case .audio: Theme.badgeAudio
        }
    }

    private var progress: some View {
        let tone = TechDetails.weight(stream.delivery) == .good ? Theme.accent : Theme.warning
        return VStack(alignment: .leading, spacing: 6) {
            Bar(share: stream.share, tint: Theme.fontQuiet)
            HStack(spacing: 6) {
                Image(icon: stream.paused ? "pause.fill" : "play.fill", size: 11)
                    .font(.app(size: 11))
                    .foregroundStyle(Theme.fontQuiet)
                Text(verbatim: stream.timeLine)
                    .font(Theme.small)
                    .monospacedDigit()
                    .foregroundStyle(Theme.fontQuiet)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
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
}

/// Children left to right, wrapping into the next line when the width runs out.
private struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews) {
            for (index, x) in row.items {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y),
                                      proposal: .unspecified)
            }
        }
    }

    private struct Row { var items: [(Int, CGFloat)] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if rows[rows.count - 1].width > 0, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            let x = row.width > 0 ? row.width + spacing : 0
            row.items.append((i, x))
            row.width = x + size.width
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

// MARK: - Logs

/// The server's log files, newest first.
struct ServerLogsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @State private var files: [ServerLogFile] = []
    @State private var failure: String?

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let failure {
                        Text(failure).font(Theme.body).foregroundStyle(Theme.error)
                            .padding(.horizontal, Theme.margin(wide: wide)).padding(.top, 18)
                    }
                    if !files.isEmpty {
                        CardView {
                            ForEach(Array(files.enumerated()), id: \.element.id) { i, file in
                                NavigationLink(value: ServerLogRoute(name: file.name)) {
                                    LogFileRow(file: file, last: i == files.count - 1)
                                }
                                .buttonStyle(Theme.PressRow())
                            }
                        }
                        .padding(.top, 18)
                    }
                }
                .padding(.bottom, 40)
                .frame(maxWidth: wide ? Theme.readWidth : .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .fadingUnderSubpageHeader(title: String(localized: "Protokoll")) { back() }
        }
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        .task {
            guard let admin = model.administration else { return }
            do { files = try await admin.logFiles() } catch { failure = model.readable(error) }
        }
    }
}

private struct LogFileRow: View {
    let file: ServerLogFile
    let last: Bool
    @Environment(\.wide) private var wide

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: file.name)
                        .font(.app(size: Theme.rowTitleSize, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: [file.modified?.formatted(date: .abbreviated, time: .shortened), file.sizeText]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontVeryQuiet)
                }
                Spacer(minLength: 0)
                Image(icon: "chevron.right", size: 13)
                    .font(.app(size: 13, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Theme.font)
            .padding(.horizontal, Theme.margin(wide: wide))
            .padding(.vertical, Theme.rowPadV)
            .frame(minHeight: Theme.rowHeight)
            if !last { SheetLine() }
        }
    }
}

/// The end of one log file, scrolled to the bottom where the latest lines are.
struct ServerLogView: View {
    let model: AppModel
    let name: String
    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @State private var text: String?
    @State private var failure: String?

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let failure {
                            Text(failure).font(Theme.body).foregroundStyle(Theme.error)
                        }
                        if let text {
                            Text(verbatim: text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.fontQuiet)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, Theme.margin(wide: wide))
                    .padding(.top, 18)
                    .padding(.bottom, 40)
                }
                .onChange(of: text) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .fadingUnderSubpageHeader(title: name) { back() }
        }
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        .task {
            guard let admin = model.administration else { return }
            do { text = try await admin.logText(name: name, limit: ServerDashboard.logLimit) }
            catch { failure = model.readable(error) }
        }
    }
}
